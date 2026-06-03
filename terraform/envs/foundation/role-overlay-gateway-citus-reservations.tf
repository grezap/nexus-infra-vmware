/*
 * role-overlay-gateway-citus-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning the Phase 0.P Citus tier (08-citus) MACs to their
 * canonical VMnet11 IPs (.202-.210). Separate file from the OLTP + Vitess
 * reservations because Citus is its own tier + repo (nexus-infra-citus).
 *
 * 9 nodes (ADR-0042):
 *   citus-etcd-1/2/3     -> .202/.203/.204   (etcd DCS)
 *   citus-coord-1/2      -> .205/.206        (coordinator Patroni pair)
 *   citus-worker1-1/2    -> .207/.208        (worker-group-1 Patroni pair)
 *   citus-worker2-1/2    -> .209/.210        (worker-group-2 Patroni pair)
 *
 * The 3 VRRP VIPs (coord/worker1/worker2 -> .211/.212/.213) are virtual: they
 * are keepalived-floated, not DHCP-leased, so they are DNS host-records
 * (role-overlay-gateway-citus-dns.tf), NOT dhcp reservations.
 *
 * Lives in foundation env (gateway is foundation's responsibility). The citus
 * env's clones consume the pinned IPs; they don't write the reservations.
 *
 * Per memory/feedback_terraform_partial_apply_destroys_resources.md: default
 * enable_citus_dhcp_reservations=true. ALL 9 MACs are trigger keys (+ the
 * version string) so a body edit forces re-create -- the 0.N N3 lesson where
 * the OLTP overlay trigger held an old version while the body grew, making a
 * plain apply a silent no-op.
 */

resource "null_resource" "gateway_citus_reservations" {
  count = var.enable_citus_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip           = "192.168.70.1"
    mac_etcd_1           = var.mac_citus_etcd_1_primary
    mac_etcd_2           = var.mac_citus_etcd_2_primary
    mac_etcd_3           = var.mac_citus_etcd_3_primary
    mac_coord_1          = var.mac_citus_coord_1_primary
    mac_coord_2          = var.mac_citus_coord_2_primary
    mac_worker1_1        = var.mac_citus_worker1_1_primary
    mac_worker1_2        = var.mac_citus_worker1_2_primary
    mac_worker2_1        = var.mac_citus_worker2_1_primary
    mac_worker2_2        = var.mac_citus_worker2_2_primary
    citus_reservations_v = "1" # v1 (0.P) = 9 Citus-tier dhcp-host pins (.202-.210). All 9 MACs are trigger keys so a body edit forces re-create.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw       = '192.168.70.1'
      $mac_e1   = '${var.mac_citus_etcd_1_primary}'
      $mac_e2   = '${var.mac_citus_etcd_2_primary}'
      $mac_e3   = '${var.mac_citus_etcd_3_primary}'
      $mac_c1   = '${var.mac_citus_coord_1_primary}'
      $mac_c2   = '${var.mac_citus_coord_2_primary}'
      $mac_w1a  = '${var.mac_citus_worker1_1_primary}'
      $mac_w1b  = '${var.mac_citus_worker1_2_primary}'
      $mac_w2a  = '${var.mac_citus_worker2_1_primary}'
      $mac_w2b  = '${var.mac_citus_worker2_2_primary}'
      $marker  = '# Citus tier dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-citus-reservations.tf v1'

      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-citus-reservations.conf && cat /etc/dnsmasq.d/foundation-citus-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway citus-reservations] v1 reservations already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "dhcp-host=$mac_e1,192.168.70.202,citus-etcd-1"
        "dhcp-host=$mac_e2,192.168.70.203,citus-etcd-2"
        "dhcp-host=$mac_e3,192.168.70.204,citus-etcd-3"
        "dhcp-host=$mac_c1,192.168.70.205,citus-coord-1"
        "dhcp-host=$mac_c2,192.168.70.206,citus-coord-2"
        "dhcp-host=$mac_w1a,192.168.70.207,citus-worker1-1"
        "dhcp-host=$mac_w1b,192.168.70.208,citus-worker1-2"
        "dhcp-host=$mac_w2a,192.168.70.209,citus-worker2-1"
        "dhcp-host=$mac_w2b,192.168.70.210,citus-worker2-2"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-citus-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway citus-reservations] writing 9 dhcp-host reservations (3 etcd + coord pair + 2 worker pairs) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway citus-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway citus-reservations] reservations live: citus-etcd-1..3 (.202-.204), citus-coord-1/2 (.205/.206), citus-worker1-1/2 (.207/.208), citus-worker2-1/2 (.209/.210)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway citus-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-citus-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
