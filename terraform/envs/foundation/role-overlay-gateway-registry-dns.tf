/*
 * role-overlay-gateway-registry-dns.tf -- Phase 0.L.4 (ADR-0036)
 *
 * Adds round-robin DNS on nexus-gateway's dnsmasq for the registry front doors
 * (the no-VIP, client-side-multi-endpoint pattern for the stateless app tier --
 * ADR-0031; plus the single VIP A-record for the stateful datastore):
 *   - registry.nexus.lab     -> the 2 Harbor app nodes (.115/.116)   [stateless HA]
 *   - registry-db.nexus.lab  -> the keepalived VRRP VIP (.119)        [datastore HA]
 *
 * Multi-A round-robin via an addn-hosts file (NOT `host-record`, which keeps only
 * ONE IPv4) -- same mechanism + conf-dir caveat as the lakehouse/analytics DNS
 * overlays. The addn-hosts file lives OUTSIDE /etc/dnsmasq.d/.
 *
 * Selective ops: var.enable_gateway_registry_dns (default true).
 */

resource "null_resource" "gateway_registry_dns" {
  count = var.enable_gateway_registry_dns ? 1 : 0

  triggers = {
    gateway_ip             = "192.168.70.1"
    registry_name          = var.registry_dns_name
    registry_ips           = join(",", var.registry_app_ips)
    registry_db_name       = var.registry_db_dns_name
    registry_db_vip        = var.registry_db_vip
    registry_dns_overlay_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $marker  = '# registry round-robin records managed by terraform/envs/foundation/role-overlay-gateway-registry-dns.tf'

      $pairs = @(
        @{ name = '${var.registry_dns_name}';    ips = '${join(",", var.registry_app_ips)}' }
        @{ name = '${var.registry_db_dns_name}'; ips = '${var.registry_db_vip}' }
      )
      $hostsLines = @()
      foreach ($p in $pairs) {
        if ($p.ips) {
          foreach ($ip in ($p.ips -split ',')) { if ($ip.Trim()) { $hostsLines += "$($ip.Trim()) $($p.name)" } }
        }
      }
      $hostsBody = ($marker, ($hostsLines -join "`n"), "") -join "`n"
      $confBody  = ($marker, "addn-hosts=/etc/dnsmasq-registry.hosts", "") -join "`n"

      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq-registry.hosts && cat /etc/dnsmasq-registry.hosts || true" 2>&1 | Out-String
      if ($existing.Trim() -eq $hostsBody.Trim()) {
        Write-Host "[gateway registry-dns] round-robin records already current, no-op."
        exit 0
      }

      $hostsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($hostsBody))
      $confB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($confBody))
      $remote = @"
set -euo pipefail
echo '$hostsB64' | base64 -d | sudo tee /etc/dnsmasq-registry.hosts > /dev/null
sudo chown root:root /etc/dnsmasq-registry.hosts
sudo chmod 0644 /etc/dnsmasq-registry.hosts
echo '$confB64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-registry-dns.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-registry-dns.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-registry-dns.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- /etc/dnsmasq-registry.hosts ---"
sudo cat /etc/dnsmasq-registry.hosts
echo "--- resolving ${var.registry_dns_name} (expect both Harbor app IPs) ---"
dig +short ${var.registry_dns_name} @127.0.0.1
"@
      $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($remote -replace "`r`n","`n")))
      $output = ssh @sshOpts "$sshUser@$gw" "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[gateway registry-dns] failed (rc=$rc)" }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@192.168.70.1" "sudo rm -f /etc/dnsmasq.d/foundation-registry-dns.conf /etc/dnsmasq-registry.hosts && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
