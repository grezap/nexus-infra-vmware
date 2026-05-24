/*
 * role-overlay-gateway-registry-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning the 09-platform registry tier MACs to canonical
 * VMnet11 IPs.
 *
 * Phase 0.L.4 layer (ADR-0036). Per nexus-platform-plan/docs/infra/vms.yaml
 * (cluster: registry), the registry nodes come up at:
 *   Harbor app (HA):  registry-1/2     -> .115 / .116
 *   Datastore (HA):   registry-pg-1/2  -> .117 / .118
 * The VRRP VIP registry-db.nexus.lab .119 is keepalived-floated (no dhcp-host).
 *
 * MAC: registry-1 reuses the canon :A4 reservation; registry-2/pg-1/pg-2 use
 * :AF/:B0/:B1 (the high-water after the 0.L.3 zookeeper-3 :AE; the :A5-:A9 gap
 * stays reserved for 0.L.5 SR shared-data). Mirrors the lakehouse reservations
 * overlay shape exactly.
 *
 * Default enable_registry_dhcp_reservations = true per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
 */

resource "null_resource" "gateway_registry_reservations" {
  count = var.enable_registry_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip              = "192.168.70.1"
    mac_registry_1          = var.mac_registry_1_primary
    mac_registry_2          = var.mac_registry_2_primary
    mac_registry_pg_1       = var.mac_registry_pg_1_primary
    mac_registry_pg_2       = var.mac_registry_pg_2_primary
    registry_reservations_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $mac_r1  = '${var.mac_registry_1_primary}'
      $mac_r2  = '${var.mac_registry_2_primary}'
      $mac_p1  = '${var.mac_registry_pg_1_primary}'
      $mac_p2  = '${var.mac_registry_pg_2_primary}'
      $marker  = '# Registry tier (Harbor HA + PG/Redis HA) dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-registry-reservations.tf v1'

      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-registry-reservations.conf && cat /etc/dnsmasq.d/foundation-registry-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway registry-reservations] reservations already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "dhcp-host=$mac_r1,192.168.70.115,registry-1"
        "dhcp-host=$mac_r2,192.168.70.116,registry-2"
        "dhcp-host=$mac_p1,192.168.70.117,registry-pg-1"
        "dhcp-host=$mac_p2,192.168.70.118,registry-pg-2"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-registry-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway registry-reservations] writing 4 registry dhcp-host reservations (2 Harbor app + 2 PG/Redis) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway registry-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway registry-reservations] reservations live: registry .115/.116, registry-pg .117/.118 (VIP .119 floats via keepalived)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway registry-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-registry-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
