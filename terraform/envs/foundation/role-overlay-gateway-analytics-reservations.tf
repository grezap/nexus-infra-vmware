/*
 * role-overlay-gateway-analytics-reservations.tf -- dnsmasq dhcp-host
 * reservations on nexus-gateway pinning the 04-analytics tier MACs to
 * canonical VMnet11 IPs.
 *
 * Phase 0.G.5/0.G.6 layer. Per nexus-platform-plan/docs/infra/vms.yaml
 * (cluster: clickhouse + cluster: starrocks), the analytics nodes come up at:
 *   ClickHouse (0.G.5):
 *     ch-keeper-1/2/3       -> 192.168.70.41 / .42 / .43
 *     ch-shard1-rep1/rep2   -> 192.168.70.44 / .45
 *     ch-shard2-rep1/rep2   -> 192.168.70.46 / .47
 *     ch-shard3-rep1/rep2   -> 192.168.70.48 / .49
 *   StarRocks (0.G.6 -- added when that sub-phase lands):
 *     sr-fe-leader/follower-1/2 -> .31 / .32 / .33
 *     sr-be-1/2/3               -> .34 / .35 / .36
 *
 * MAC block :8A-:98 (the contiguous range after the OLTP tier, which ends at
 * :89). This overlay seeds the 9 ClickHouse reservations (:8A-:92); the 6
 * StarRocks reservations (:93-:98) are added when 0.G.6 lands. Mirrors
 * role-overlay-gateway-kafka-reservations.tf shape exactly.
 *
 * Default enable_analytics_dhcp_reservations = true per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
 */

resource "null_resource" "gateway_analytics_reservations" {
  count = var.enable_analytics_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip               = "192.168.70.1"
    mac_k1                   = var.mac_analytics_ch_keeper_1_primary
    mac_k2                   = var.mac_analytics_ch_keeper_2_primary
    mac_k3                   = var.mac_analytics_ch_keeper_3_primary
    mac_s1r1                 = var.mac_analytics_ch_shard1_rep1_primary
    mac_s1r2                 = var.mac_analytics_ch_shard1_rep2_primary
    mac_s2r1                 = var.mac_analytics_ch_shard2_rep1_primary
    mac_s2r2                 = var.mac_analytics_ch_shard2_rep2_primary
    mac_s3r1                 = var.mac_analytics_ch_shard3_rep1_primary
    mac_s3r2                 = var.mac_analytics_ch_shard3_rep2_primary
    mac_fel                  = var.mac_analytics_sr_fe_leader_primary
    mac_ff1                  = var.mac_analytics_sr_fe_follower_1_primary
    mac_ff2                  = var.mac_analytics_sr_fe_follower_2_primary
    mac_be1                  = var.mac_analytics_sr_be_1_primary
    mac_be2                  = var.mac_analytics_sr_be_2_primary
    mac_be3                  = var.mac_analytics_sr_be_3_primary
    analytics_reservations_v = "2" # v2 (0.G.6) = 9 ClickHouse (:8A-:92 -> .41-.49) + 6 StarRocks (:93-:98 -> .31-.36). v1 = ClickHouse only.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw     = '192.168.70.1'
      $mac_k1   = '${var.mac_analytics_ch_keeper_1_primary}'
      $mac_k2   = '${var.mac_analytics_ch_keeper_2_primary}'
      $mac_k3   = '${var.mac_analytics_ch_keeper_3_primary}'
      $mac_s1r1 = '${var.mac_analytics_ch_shard1_rep1_primary}'
      $mac_s1r2 = '${var.mac_analytics_ch_shard1_rep2_primary}'
      $mac_s2r1 = '${var.mac_analytics_ch_shard2_rep1_primary}'
      $mac_s2r2 = '${var.mac_analytics_ch_shard2_rep2_primary}'
      $mac_s3r1 = '${var.mac_analytics_ch_shard3_rep1_primary}'
      $mac_s3r2 = '${var.mac_analytics_ch_shard3_rep2_primary}'
      $mac_fel  = '${var.mac_analytics_sr_fe_leader_primary}'
      $mac_ff1  = '${var.mac_analytics_sr_fe_follower_1_primary}'
      $mac_ff2  = '${var.mac_analytics_sr_fe_follower_2_primary}'
      $mac_be1  = '${var.mac_analytics_sr_be_1_primary}'
      $mac_be2  = '${var.mac_analytics_sr_be_2_primary}'
      $mac_be3  = '${var.mac_analytics_sr_be_3_primary}'
      $marker = '# Analytics tier (ClickHouse + StarRocks) dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-analytics-reservations.tf v2'

      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-analytics-reservations.conf && cat /etc/dnsmasq.d/foundation-analytics-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway analytics-reservations] v2 reservations already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "dhcp-host=$mac_k1,192.168.70.41,ch-keeper-1"
        "dhcp-host=$mac_k2,192.168.70.42,ch-keeper-2"
        "dhcp-host=$mac_k3,192.168.70.43,ch-keeper-3"
        "dhcp-host=$mac_s1r1,192.168.70.44,ch-shard1-rep1"
        "dhcp-host=$mac_s1r2,192.168.70.45,ch-shard1-rep2"
        "dhcp-host=$mac_s2r1,192.168.70.46,ch-shard2-rep1"
        "dhcp-host=$mac_s2r2,192.168.70.47,ch-shard2-rep2"
        "dhcp-host=$mac_s3r1,192.168.70.48,ch-shard3-rep1"
        "dhcp-host=$mac_s3r2,192.168.70.49,ch-shard3-rep2"
        "dhcp-host=$mac_fel,192.168.70.31,sr-fe-leader"
        "dhcp-host=$mac_ff1,192.168.70.32,sr-fe-follower-1"
        "dhcp-host=$mac_ff2,192.168.70.33,sr-fe-follower-2"
        "dhcp-host=$mac_be1,192.168.70.34,sr-be-1"
        "dhcp-host=$mac_be2,192.168.70.35,sr-be-2"
        "dhcp-host=$mac_be3,192.168.70.36,sr-be-3"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-analytics-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway analytics-reservations] writing 15 analytics dhcp-host reservations (9 ClickHouse + 6 StarRocks) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway analytics-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway analytics-reservations] reservations live: ch .41-.49, sr-fe .31-.33, sr-be .34-.36"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway analytics-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-analytics-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
