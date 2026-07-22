/*
 * role-overlay-gateway-platform-tools-dns.tf -- Phase 0.Q.1 (ADR-0043)
 *
 * Adds DNS on nexus-gateway's dnsmasq for the Marquez front doors:
 *   - marquez.nexus.lab     -> the Marquez app node (.127)   [single app node]
 *   - marquez-db.nexus.lab  -> the keepalived VRRP VIP (.136) [datastore HA]
 *
 * Both are single-A today. The addn-hosts mechanism is used (NOT `host-record`)
 * to mirror the same-tier registry DNS overlay and so the app node can grow to
 * an HA pair without changing mechanism -- `host-record` keeps only ONE IPv4,
 * which is exactly the trap the lakehouse/analytics overlays documented. The
 * addn-hosts file lives OUTSIDE /etc/dnsmasq.d/.
 *
 * Both names are carried in the corresponding platform-tools-server leaf SANs:
 * marquez.nexus.lab on the app node, marquez-db.nexus.lab + .136 on BOTH
 * marquez-pg nodes (either may hold the VIP, so either must satisfy PG TLS
 * verification through it).
 *
 * Selective ops: var.enable_gateway_platform_tools_dns (default true).
 */

resource "null_resource" "gateway_platform_tools_dns" {
  count = var.enable_gateway_platform_tools_dns ? 1 : 0

  triggers = {
    gateway_ip                   = "192.168.70.1"
    marquez_name                 = var.marquez_dns_name
    marquez_ips                  = join(",", var.marquez_app_ips)
    marquez_db_name              = var.marquez_db_dns_name
    marquez_db_vip               = var.marquez_db_vip
    platform_tools_dns_overlay_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $marker  = '# platform-tools (Marquez) records managed by terraform/envs/foundation/role-overlay-gateway-platform-tools-dns.tf'

      $pairs = @(
        @{ name = '${var.marquez_dns_name}';    ips = '${join(",", var.marquez_app_ips)}' }
        @{ name = '${var.marquez_db_dns_name}'; ips = '${var.marquez_db_vip}' }
      )
      $hostsLines = @()
      foreach ($p in $pairs) {
        if ($p.ips) {
          foreach ($ip in ($p.ips -split ',')) { if ($ip.Trim()) { $hostsLines += "$($ip.Trim()) $($p.name)" } }
        }
      }
      $hostsBody = ($marker, ($hostsLines -join "`n"), "") -join "`n"
      $confBody  = ($marker, "addn-hosts=/etc/dnsmasq-platform-tools.hosts", "") -join "`n"

      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq-platform-tools.hosts && cat /etc/dnsmasq-platform-tools.hosts || true" 2>&1 | Out-String
      if ($existing.Trim() -eq $hostsBody.Trim()) {
        Write-Host "[gateway platform-tools-dns] records already current, no-op."
        exit 0
      }

      $hostsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($hostsBody))
      $confB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($confBody))
      $remote = @"
set -euo pipefail
echo '$hostsB64' | base64 -d | sudo tee /etc/dnsmasq-platform-tools.hosts > /dev/null
sudo chown root:root /etc/dnsmasq-platform-tools.hosts
sudo chmod 0644 /etc/dnsmasq-platform-tools.hosts
echo '$confB64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-platform-tools-dns.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-platform-tools-dns.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-platform-tools-dns.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- /etc/dnsmasq-platform-tools.hosts ---"
sudo cat /etc/dnsmasq-platform-tools.hosts
echo "--- resolving ${var.marquez_dns_name} (expect .127) ---"
dig +short ${var.marquez_dns_name} @127.0.0.1
echo "--- resolving ${var.marquez_db_dns_name} (expect the VIP ${var.marquez_db_vip}) ---"
dig +short ${var.marquez_db_dns_name} @127.0.0.1
"@
      $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($remote -replace "`r`n","`n")))
      $output = ssh @sshOpts "$sshUser@$gw" "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[gateway platform-tools-dns] failed (rc=$rc)" }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@192.168.70.1" "sudo rm -f /etc/dnsmasq.d/foundation-platform-tools-dns.conf /etc/dnsmasq-platform-tools.hosts && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
