/*
 * role-overlay-gateway-analytics-dns.tf -- Phase 0.G.5/0.G.6
 *
 * Adds multi-A round-robin DNS host-records on nexus-gateway's dnsmasq for the
 * analytics cluster front doors (the documented no-VIP, client-side-multi-
 * endpoint pattern -- ADR-0031):
 *   - clickhouse.nexus.lab   -> the 6 ClickHouse data nodes (.44-.49)   [0.G.5]
 *   - starrocks-fe.nexus.lab -> the 3 StarRocks FE (.31-.33)            [0.G.6]
 *
 * Multi-A round-robin via an addn-hosts file (NOT `host-record`): dnsmasq's
 * `host-record=name,IP[,IP]...` keeps only ONE IPv4 (later IPs overwrite the
 * earlier), so it returns a single address -- it does NOT round-robin a name
 * across N nodes (proven at live ratification -- handbook §3.x). The hosts-file
 * form returns ALL A records for a name and rotates them (the same mechanism
 * the gateway already uses for hosts.nexus). We write the hosts file at
 * /etc/dnsmasq-analytics.hosts (one `IP  name` line per node) and pull it in
 * with `addn-hosts=`. CRITICAL: the gateway's conf-dir parses EVERY file in
 * /etc/dnsmasq.d/ as config (not just *.conf -- hosts.nexus survives only
 * because it is comment-only), so a hosts file placed there errors out at
 * startup ("bad option at line N"). The addn-hosts file therefore lives
 * OUTSIDE /etc/dnsmasq.d/; only the .conf (valid config) stays in the conf-dir.
 *
 * Resolvers round-robin/rotate the N addresses, and both engines' native multi-
 * host clients retry the next address on failure. No VIP, no LB pair -- there
 * is no single mandatory endpoint that would be a SPOF (ADR-0031). The per-host
 * TLS leaf certs carry the round-robin name in their SANs so verify-full
 * validates whichever node answers.
 *
 * The StarRocks lines are written too when its IPs are provided
 * (var.analytics_starrocks_fe_ips non-empty); at 0.G.5 it can be left empty and
 * only the ClickHouse lines are written.
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
    analytics_dns_overlay_v = "2" # v2: multi-A round-robin via addn-hosts (one IP/line); host-record kept only the last IP so the name resolved to a single node, defeating ADR-0031's no-VIP round-robin.
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
      $marker  = '# analytics round-robin records managed by terraform/envs/foundation/role-overlay-gateway-analytics-dns.tf'

      # Multi-A round-robin needs hosts-file form (one "IP name" line per node);
      # host-record keeps only the last IP. The .conf just pulls in the hosts
      # file via addn-hosts.
      $hostsLines = @()
      foreach ($ip in ($chIps -split ',')) { if ($ip.Trim()) { $hostsLines += "$($ip.Trim()) $chName" } }
      if ($srIps) { foreach ($ip in ($srIps -split ',')) { if ($ip.Trim()) { $hostsLines += "$($ip.Trim()) $srName" } } }
      $hostsBody = ($marker, ($hostsLines -join "`n"), "") -join "`n"
      # The addn-hosts file MUST live outside /etc/dnsmasq.d/ -- conf-dir parses
      # every file there as config and a hosts file errors ("bad option").
      $confBody  = ($marker, "addn-hosts=/etc/dnsmasq-analytics.hosts", "") -join "`n"

      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq-analytics.hosts && cat /etc/dnsmasq-analytics.hosts || true" 2>&1 | Out-String
      if ($existing.Trim() -eq $hostsBody.Trim()) {
        Write-Host "[gateway analytics-dns] round-robin records already current, no-op."
        exit 0
      }

      $hostsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($hostsBody))
      $confB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($confBody))
      $remote = @"
set -euo pipefail
# Remove any stale copy from a prior (broken) layout inside the conf-dir.
sudo rm -f /etc/dnsmasq.d/hosts.analytics
echo '$hostsB64' | base64 -d | sudo tee /etc/dnsmasq-analytics.hosts > /dev/null
sudo chown root:root /etc/dnsmasq-analytics.hosts
sudo chmod 0644 /etc/dnsmasq-analytics.hosts
echo '$confB64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-analytics-dns.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-analytics-dns.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-analytics-dns.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- /etc/dnsmasq-analytics.hosts ---"
sudo cat /etc/dnsmasq-analytics.hosts
echo "--- resolving $chName (expect all data-node IPs) ---"
dig +short $chName @127.0.0.1
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
      ssh @sshOpts "$sshUser@192.168.70.1" "sudo rm -f /etc/dnsmasq.d/foundation-analytics-dns.conf /etc/dnsmasq.d/hosts.analytics /etc/dnsmasq-analytics.hosts && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
