/*
 * role-overlay-gateway-vitess-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning the Phase 0.O Vitess tier (07-vitess) MACs to their
 * canonical VMnet11 IPs (.190-.201). Separate file from the OLTP reservations
 * because Vitess is its own tier + repo (nexus-infra-vitess).
 *
 * 12 nodes (ADR-0041):
 *   vitess-etcd-1/2/3          -> .190/.191/.192   (etcd topo)
 *   vitess-control-1           -> .193             (vtctld + VTOrc)
 *   vitess-vtgate-1/2          -> .194/.195        (vtgate routers)
 *   vitess-shard1-tablet-1/2/3 -> .196/.197/.198   (shard -80)
 *   vitess-shard2-tablet-1/2/3 -> .199/.200/.201   (shard 80-)
 *
 * The vtgate round-robin DNS front door `vtgate.nexus.lab -> .194,.195` is a
 * DNS record (role-overlay-gateway-dns or the vitess DNS overlay), NOT a dhcp
 * reservation -- vtgate is stateless with no VIP (ADR-0031).
 *
 * Lives in foundation env (gateway is foundation's responsibility). The vitess
 * env's clones consume the pinned IPs; they don't write the reservations.
 *
 * Per memory/feedback_terraform_partial_apply_destroys_resources.md: default
 * enable_vitess_dhcp_reservations=true. ALL 12 MACs are trigger keys (+ the
 * version string) so a body edit forces re-create -- the 0.N N3 lesson where
 * the OLTP overlay trigger held an old version while the body grew, making a
 * plain apply a silent no-op.
 */

resource "null_resource" "gateway_vitess_reservations" {
  count = var.enable_vitess_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip            = "192.168.70.1"
    mac_etcd_1            = var.mac_vitess_etcd_1_primary
    mac_etcd_2            = var.mac_vitess_etcd_2_primary
    mac_etcd_3            = var.mac_vitess_etcd_3_primary
    mac_control_1         = var.mac_vitess_control_1_primary
    mac_vtgate_1          = var.mac_vitess_vtgate_1_primary
    mac_vtgate_2          = var.mac_vitess_vtgate_2_primary
    mac_shard1_tablet_1   = var.mac_vitess_shard1_tablet_1_primary
    mac_shard1_tablet_2   = var.mac_vitess_shard1_tablet_2_primary
    mac_shard1_tablet_3   = var.mac_vitess_shard1_tablet_3_primary
    mac_shard2_tablet_1   = var.mac_vitess_shard2_tablet_1_primary
    mac_shard2_tablet_2   = var.mac_vitess_shard2_tablet_2_primary
    mac_shard2_tablet_3   = var.mac_vitess_shard2_tablet_3_primary
    vitess_reservations_v = "1" # v1 (0.O) = 12 Vitess-tier dhcp-host pins (.190-.201). All 12 MACs are trigger keys so a body edit forces re-create.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw       = '192.168.70.1'
      $mac_e1   = '${var.mac_vitess_etcd_1_primary}'
      $mac_e2   = '${var.mac_vitess_etcd_2_primary}'
      $mac_e3   = '${var.mac_vitess_etcd_3_primary}'
      $mac_ctl  = '${var.mac_vitess_control_1_primary}'
      $mac_vg1  = '${var.mac_vitess_vtgate_1_primary}'
      $mac_vg2  = '${var.mac_vitess_vtgate_2_primary}'
      $mac_s1t1 = '${var.mac_vitess_shard1_tablet_1_primary}'
      $mac_s1t2 = '${var.mac_vitess_shard1_tablet_2_primary}'
      $mac_s1t3 = '${var.mac_vitess_shard1_tablet_3_primary}'
      $mac_s2t1 = '${var.mac_vitess_shard2_tablet_1_primary}'
      $mac_s2t2 = '${var.mac_vitess_shard2_tablet_2_primary}'
      $mac_s2t3 = '${var.mac_vitess_shard2_tablet_3_primary}'
      $marker  = '# Vitess tier dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-vitess-reservations.tf v1'

      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-vitess-reservations.conf && cat /etc/dnsmasq.d/foundation-vitess-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway vitess-reservations] v1 reservations already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "dhcp-host=$mac_e1,192.168.70.190,vitess-etcd-1"
        "dhcp-host=$mac_e2,192.168.70.191,vitess-etcd-2"
        "dhcp-host=$mac_e3,192.168.70.192,vitess-etcd-3"
        "dhcp-host=$mac_ctl,192.168.70.193,vitess-control-1"
        "dhcp-host=$mac_vg1,192.168.70.194,vitess-vtgate-1"
        "dhcp-host=$mac_vg2,192.168.70.195,vitess-vtgate-2"
        "dhcp-host=$mac_s1t1,192.168.70.196,vitess-shard1-tablet-1"
        "dhcp-host=$mac_s1t2,192.168.70.197,vitess-shard1-tablet-2"
        "dhcp-host=$mac_s1t3,192.168.70.198,vitess-shard1-tablet-3"
        "dhcp-host=$mac_s2t1,192.168.70.199,vitess-shard2-tablet-1"
        "dhcp-host=$mac_s2t2,192.168.70.200,vitess-shard2-tablet-2"
        "dhcp-host=$mac_s2t3,192.168.70.201,vitess-shard2-tablet-3"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-vitess-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway vitess-reservations] writing 12 dhcp-host reservations (3 etcd + 1 control + 2 vtgate + 2x3 tablets) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway vitess-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway vitess-reservations] reservations live: vitess-etcd-1..3 (.190-.192), vitess-control-1 (.193), vitess-vtgate-1..2 (.194/.195), vitess-shard1-tablet-1..3 (.196-.198), vitess-shard2-tablet-1..3 (.199-.201)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway vitess-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-vitess-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
