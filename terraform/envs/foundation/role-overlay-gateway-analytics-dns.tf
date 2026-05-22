/*
 * role-overlay-gateway-analytics-dns.tf -- Phase 0.G.5/0.G.6
 *
 * Adds multi-A round-robin DNS host-records on nexus-gateway's dnsmasq for the
 * analytics cluster front doors (the documented no-VIP, client-side-multi-
 * endpoint pattern -- ADR-0031):
 *   - clickhouse.nexus.lab   -> the 6 ClickHouse data nodes (.44-.49)   [0.G.5]
 *   - starrocks-fe.nexus.lab -> the 3 StarRocks FE (.31-.33)            [0.G.6]
 *
 * dnsmasq `host-record=name,IP[,IP]...` registers all IPs under one name;
 * resolvers round-robin/rotate, and both engines' native multi-host clients
 * retry the next address on failure. No VIP, no LB pair -- there is no single
 * mandatory endpoint that would be a SPOF (ADR-0031). The per-host TLS leaf
 * certs carry the round-robin name in their SANs so verify-full validates
 * whichever node answers.
 *
 * Mirrors role-overlay-gateway-portainer-dns.tf shape (idempotent marker;
 * skip-if-present). The StarRocks record is written too when its IPs are
 * provided (var.analytics_starrocks_fe_ips non-empty); at 0.G.5 it can be
 * left empty and only the ClickHouse record is written.
 *
 * Selective ops: var.enable_gateway_analytics_dns (default true).
 */

resource "null_resource" "gateway_analytics_dns" {
  count = var.enable_gateway_analytics_dns ? 1 : 0

  triggers = {
    gateway_ip              = "192.168.70.1"
    clickhouse_name         = var.analytics_clickhouse_dns_name
    clickhouse_ips          = join(",", var.analytics_clickhouse_data_ips)
    starrocks_name          = var.analytics_starrocks_dns_name
    starrocks_ips           = join(",", var.analytics_starrocks_fe_ips)
    analytics_dns_overlay_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $chName  = '${var.analytics_clickhouse_dns_name}'
      $chIps   = '${join(",", var.analytics_clickhouse_data_ips)}'
      $srName  = '${var.analytics_starrocks_dns_name}'
      $srIps   = '${join(",", var.analytics_starrocks_fe_ips)}'
      $marker  = '# analytics round-robin host-records managed by terraform/envs/foundation/role-overlay-gateway-analytics-dns.tf'

      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq.d/foundation-analytics-dns.conf && cat /etc/dnsmasq.d/foundation-analytics-dns.conf || true" 2>&1 | Out-String
      # Re-render when the record set changes; marker alone isn't enough since
      # StarRocks IPs may be added later. Compare the desired body.
      $lines = @($marker)
      if ($chIps) { $lines += "host-record=$chName,$chIps" }
      if ($srIps) { $lines += "host-record=$srName,$srIps" }
      $desired = ($lines + "") -join "`n"

      if ($existing.Trim() -eq $desired.Trim()) {
        Write-Host "[gateway analytics-dns] records already current, no-op."
        exit 0
      }

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($desired))
      $remote = @"
set -euo pipefail
echo '$b64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-analytics-dns.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-analytics-dns.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-analytics-dns.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- foundation-analytics-dns.conf ---"
sudo cat /etc/dnsmasq.d/foundation-analytics-dns.conf
"@
      $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($remote -replace "`r`n","`n")))
      $output = ssh @sshOpts "$sshUser@$gw" "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[gateway analytics-dns] failed (rc=$rc)" }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@192.168.70.1" "sudo rm -f /etc/dnsmasq.d/foundation-analytics-dns.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
