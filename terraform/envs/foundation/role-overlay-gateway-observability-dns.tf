/*
 * role-overlay-gateway-observability-dns.tf -- Phase 0.I (ADR-0038)
 *
 * Adds multi-A round-robin DNS records on nexus-gateway's dnsmasq for the
 * Phase 0.I observability tier (no-VIP machine endpoints per ADR-0031) +
 * single-A records for the 2 VRRP VIPs (Grafana + Grafana PG per ADR-0025):
 *   - prometheus.nexus.lab    -> prom-1/2          (.170/.171)          [0.I.1]
 *   - alertmanager.nexus.lab  -> prom-1/2          (.170/.171)          [0.I.1]
 *   - loki.nexus.lab          -> loki-1/2/3        (.172-.174)          [0.I.2]
 *   - tempo.nexus.lab         -> tempo-1/2/3       (.175-.177)          [0.I.3]
 *   - otel.nexus.lab          -> otel-collector-1/2 (.182/.183)         [0.I.5]
 *   - grafana.nexus.lab       -> VRRP VIP .184 (single A)               [0.I.4]
 *   - grafana-db.nexus.lab    -> VRRP VIP .185 (single A)               [0.I.4]
 *
 * Multi-A round-robin via an addn-hosts file (NOT `host-record`, which keeps
 * only ONE IPv4) -- same mechanism + conf-dir caveat as the lakehouse-dns
 * overlay. addn-hosts file lives OUTSIDE /etc/dnsmasq.d/.
 *
 * Selective ops: var.enable_gateway_observability_dns (default true).
 */

resource "null_resource" "gateway_observability_dns" {
  count = var.enable_gateway_observability_dns ? 1 : 0

  triggers = {
    gateway_ip                  = "192.168.70.1"
    prom_name                   = var.obs_prometheus_dns_name
    prom_ips                    = join(",", var.obs_prometheus_ips)
    alertmanager_name           = var.obs_alertmanager_dns_name
    alertmanager_ips            = join(",", var.obs_alertmanager_ips)
    loki_name                   = var.obs_loki_dns_name
    loki_ips                    = join(",", var.obs_loki_ips)
    tempo_name                  = var.obs_tempo_dns_name
    tempo_ips                   = join(",", var.obs_tempo_ips)
    otel_name                   = var.obs_otel_dns_name
    otel_ips                    = join(",", var.obs_otel_ips)
    grafana_name                = var.obs_grafana_dns_name
    grafana_vip                 = var.obs_grafana_vip
    grafana_db_name             = var.obs_grafana_db_dns_name
    grafana_db_vip              = var.obs_grafana_db_vip
    observability_dns_overlay_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $marker  = '# observability round-robin + VIP records managed by terraform/envs/foundation/role-overlay-gateway-observability-dns.tf'

      $pairs = @(
        @{ name = '${var.obs_prometheus_dns_name}';   ips = '${join(",", var.obs_prometheus_ips)}' }
        @{ name = '${var.obs_alertmanager_dns_name}'; ips = '${join(",", var.obs_alertmanager_ips)}' }
        @{ name = '${var.obs_loki_dns_name}';         ips = '${join(",", var.obs_loki_ips)}' }
        @{ name = '${var.obs_tempo_dns_name}';        ips = '${join(",", var.obs_tempo_ips)}' }
        @{ name = '${var.obs_otel_dns_name}';         ips = '${join(",", var.obs_otel_ips)}' }
        @{ name = '${var.obs_grafana_dns_name}';      ips = '${var.obs_grafana_vip}' }
        @{ name = '${var.obs_grafana_db_dns_name}';   ips = '${var.obs_grafana_db_vip}' }
      )
      # Also emit per-host A-records for the 14 obs hostnames (prom-1.nexus.lab,
      # etc.) -- the dhcp-host reservation already gives them PTR resolution but
      # we also need forward A for cert SAN validation in Vault Agent templates.
      $hosts = @(
        @{ name = 'prom-1.nexus.lab';            ip = '192.168.70.170' }
        @{ name = 'prom-2.nexus.lab';            ip = '192.168.70.171' }
        @{ name = 'loki-1.nexus.lab';            ip = '192.168.70.172' }
        @{ name = 'loki-2.nexus.lab';            ip = '192.168.70.173' }
        @{ name = 'loki-3.nexus.lab';            ip = '192.168.70.174' }
        @{ name = 'tempo-1.nexus.lab';           ip = '192.168.70.175' }
        @{ name = 'tempo-2.nexus.lab';           ip = '192.168.70.176' }
        @{ name = 'tempo-3.nexus.lab';           ip = '192.168.70.177' }
        @{ name = 'grafana-1.nexus.lab';         ip = '192.168.70.178' }
        @{ name = 'grafana-2.nexus.lab';         ip = '192.168.70.179' }
        @{ name = 'grafana-pg-1.nexus.lab';      ip = '192.168.70.180' }
        @{ name = 'grafana-pg-2.nexus.lab';      ip = '192.168.70.181' }
        @{ name = 'otel-collector-1.nexus.lab';  ip = '192.168.70.182' }
        @{ name = 'otel-collector-2.nexus.lab';  ip = '192.168.70.183' }
      )

      $hostsLines = @()
      foreach ($p in $pairs) {
        if ($p.ips) {
          foreach ($ip in ($p.ips -split ',')) { if ($ip.Trim()) { $hostsLines += "$($ip.Trim()) $($p.name)" } }
        }
      }
      foreach ($h in $hosts) {
        $hostsLines += "$($h.ip) $($h.name)"
      }
      $hostsBody = ($marker, ($hostsLines -join "`n"), "") -join "`n"
      $confBody  = ($marker, "addn-hosts=/etc/dnsmasq-observability.hosts", "") -join "`n"

      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq-observability.hosts && cat /etc/dnsmasq-observability.hosts || true" 2>&1 | Out-String
      if ($existing.Trim() -eq $hostsBody.Trim()) {
        Write-Host "[gateway observability-dns] records already current, no-op."
        exit 0
      }

      $hostsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($hostsBody))
      $confB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($confBody))
      $remote = @"
set -euo pipefail
echo '$hostsB64' | base64 -d | sudo tee /etc/dnsmasq-observability.hosts > /dev/null
sudo chown root:root /etc/dnsmasq-observability.hosts
sudo chmod 0644 /etc/dnsmasq-observability.hosts
echo '$confB64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-observability-dns.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-observability-dns.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-observability-dns.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- /etc/dnsmasq-observability.hosts ---"
sudo cat /etc/dnsmasq-observability.hosts
echo "--- resolving ${var.obs_prometheus_dns_name} (expect both Prom IPs) ---"
dig +short ${var.obs_prometheus_dns_name} @127.0.0.1
echo "--- resolving ${var.obs_grafana_dns_name} (expect VIP .184) ---"
dig +short ${var.obs_grafana_dns_name} @127.0.0.1
"@
      $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($remote -replace "`r`n","`n")))
      $output = ssh @sshOpts "$sshUser@$gw" "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[gateway observability-dns] failed (rc=$rc)" }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@192.168.70.1" "sudo rm -f /etc/dnsmasq-observability.hosts /etc/dnsmasq.d/foundation-observability-dns.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
