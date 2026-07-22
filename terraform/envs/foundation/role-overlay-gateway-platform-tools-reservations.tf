/*
 * role-overlay-gateway-platform-tools-reservations.tf -- dnsmasq dhcp-host
 * reservations on nexus-gateway pinning the 09-platform Marquez tier MACs to
 * canonical VMnet11 IPs.
 *
 * Phase 0.Q.1 layer (ADR-0043). Per nexus-platform-plan/docs/infra/vms.yaml
 * (cluster: platform-tools), the Marquez nodes come up at:
 *   Marquez app:      marquez         -> .127
 *   Datastore (HA):   marquez-pg-1/2  -> .134 / .135
 * The VRRP VIP marquez-db.nexus.lab .136 is keepalived-floated (no dhcp-host).
 *
 * MAC: :E0/:E1/:E2 -- the contiguous block just past the 0.P citus high-water
 * :DF. Pre-apply MAC+IP audit ALL CLEAR 2026-07-20 vs every foundation
 * reservation file and every sibling repo. Mirrors the registry reservations
 * overlay shape exactly (same tier, same pattern).
 *
 * Note the IP discontinuity: marquez keeps its long-reserved .127 slot in the
 * platform-tools .125-.128 band while the datastore pair takes .134/.135 (the
 * nearest contiguous free block -- .131-.133 are Swarm workers). MACs are
 * allocated by build order, not by IP, so the MAC block stays contiguous.
 *
 * Default enable_platform_tools_dhcp_reservations = true per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
 */

resource "null_resource" "gateway_platform_tools_reservations" {
  count = var.enable_platform_tools_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip                    = "192.168.70.1"
    mac_marquez                   = var.mac_marquez_primary
    mac_marquez_pg_1              = var.mac_marquez_pg_1_primary
    mac_marquez_pg_2              = var.mac_marquez_pg_2_primary
    platform_tools_reservations_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw     = '192.168.70.1'
      $mac_mq = '${var.mac_marquez_primary}'
      $mac_p1 = '${var.mac_marquez_pg_1_primary}'
      $mac_p2 = '${var.mac_marquez_pg_2_primary}'
      $marker = '# Platform-tools tier (Marquez + lineage PG HA) dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-platform-tools-reservations.tf v1'

      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-platform-tools-reservations.conf && cat /etc/dnsmasq.d/foundation-platform-tools-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway platform-tools-reservations] reservations already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "dhcp-host=$mac_mq,192.168.70.127,marquez"
        "dhcp-host=$mac_p1,192.168.70.134,marquez-pg-1"
        "dhcp-host=$mac_p2,192.168.70.135,marquez-pg-2"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-platform-tools-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway platform-tools-reservations] writing 3 Marquez dhcp-host reservations (1 app + 2 lineage PG) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway platform-tools-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway platform-tools-reservations] reservations live: marquez .127, marquez-pg .134/.135 (VIP .136 floats via keepalived)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway platform-tools-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-platform-tools-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
