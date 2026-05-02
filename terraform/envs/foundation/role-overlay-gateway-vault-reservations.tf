/*
 * role-overlay-gateway-vault-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning vault-1/2/3 MACs to canonical VMnet11 IPs.
 *
 * Phase 0.D.1 layer. Per nexus-platform-plan/docs/infra/vms.yaml lines 55-57,
 * vault-1/2/3 must come up at canonical IPs 192.168.70.121/.122/.123 on the
 * VMnet11 service network. nexus-gateway's dnsmasq dynamic DHCP pool is
 * .200-.250 (Phase 0.B.1 baked default; we don't touch it). dnsmasq honors
 * `dhcp-host=<MAC>,<IP>,<hostname>` reservations REGARDLESS of whether the
 * IP falls inside dhcp-range, so we add per-MAC reservations here without
 * modifying the gateway template.
 *
 * Lives in foundation env (not envs/security/) because the gateway is
 * foundation's responsibility -- the security env's Vault clones are the
 * consumer, but the reservations themselves are gateway-config infrastructure.
 *
 * Default `enable_vault_dhcp_reservations = false` so existing
 * `pwsh -File scripts\foundation.ps1 apply` runs that don't intend to bring
 * up Vault don't touch the gateway. Set true (or use -Vars enable_...=true)
 * when deploying the security env.
 *
 * Mirrors the existing role-overlay-gateway-dns.tf shape:
 *   - SSH to gateway, write /etc/dnsmasq.d/foundation-vault-reservations.conf
 *   - Marker comment for idempotent re-apply
 *   - systemctl restart dnsmasq (NOT reload; reload doesn't re-read
 *     dhcp-host entries reliably)
 *   - Destroy-time provisioner removes the conf + reloads
 *
 * Reachability invariant (memory/feedback_lab_host_reachability.md):
 *   - Pinning Vault VMs to known IPs makes build-host -> Vault SSH/22 + 8200
 *     deterministic. The reservations don't change firewall behavior;
 *     gateway dnsmasq just allocates the canonical IP via DHCP.
 */

resource "null_resource" "gateway_vault_reservations" {
  count = var.enable_vault_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip           = "192.168.70.1"
    mac_vault_1          = var.mac_vault_1_primary
    mac_vault_2          = var.mac_vault_2_primary
    mac_vault_3          = var.mac_vault_3_primary
    mac_vault_transit    = var.mac_vault_transit_primary
    vault_reservations_v = "2" # v2 = also pins vault-transit (.124) for Phase 0.D.5.5 transit auto-unseal. v1 = vault-1/2/3 only.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw          = '192.168.70.1'
      $mac_v1      = '${var.mac_vault_1_primary}'
      $mac_v2      = '${var.mac_vault_2_primary}'
      $mac_v3      = '${var.mac_vault_3_primary}'
      $mac_vt      = '${var.mac_vault_transit_primary}'
      $marker      = '# Vault cluster dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-vault-reservations.tf v2'

      # Idempotent insert: marker includes version (v2 adds vault-transit);
      # v1 marker would no-op match without the new entry, so we look for
      # the v2 marker specifically.
      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-vault-reservations.conf && cat /etc/dnsmasq.d/foundation-vault-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway vault-reservations] v2 reservations already present, no-op."
        exit 0
      }

      # Per nexus-platform-plan/docs/infra/vms.yaml lines 55-58.
      $confLines = @(
        $marker
        "dhcp-host=$mac_v1,192.168.70.121,vault-1"
        "dhcp-host=$mac_v2,192.168.70.122,vault-2"
        "dhcp-host=$mac_v3,192.168.70.123,vault-3"
        "dhcp-host=$mac_vt,192.168.70.124,vault-transit"
        ""
      ) -join "`n"

      # Restart (not reload) -- dhcp-host entries need a full restart for
      # dnsmasq to reliably honor them on subsequent DHCP requests.
      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-vault-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway vault-reservations] writing dhcp-host reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway vault-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway vault-reservations] reservations live: vault-1=.121, vault-2=.122, vault-3=.123, vault-transit=.124"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway vault-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-vault-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
