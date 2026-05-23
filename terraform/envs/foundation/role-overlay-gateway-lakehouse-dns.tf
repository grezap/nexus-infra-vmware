/*
 * role-overlay-gateway-lakehouse-dns.tf -- Phase 0.L
 *
 * Adds multi-A round-robin DNS records on nexus-gateway's dnsmasq for the
 * lakehouse cluster front doors (the no-VIP, client-side-multi-endpoint pattern
 * -- ADR-0031/0033):
 *   - minio.nexus.lab         -> the 4 MinIO nodes (.141-.144)   [0.L.1]
 *   - iceberg.nexus.lab       -> the 2 Iceberg REST nodes (.147-.148) [0.L.2]
 *   - spark-master.nexus.lab  -> the Spark master (.140)         [0.L.3]
 *
 * Multi-A round-robin via an addn-hosts file (NOT `host-record`, which keeps
 * only ONE IPv4) -- the same mechanism + the same conf-dir caveat documented in
 * role-overlay-gateway-analytics-dns.tf. The addn-hosts file lives OUTSIDE
 * /etc/dnsmasq.d/ (the conf-dir parses every file as config). Only names with a
 * non-empty IP list are written, so 0.L.1 writes just minio.nexus.lab and the
 * iceberg/spark IPs are populated when 0.L.2/0.L.3 land.
 *
 * Selective ops: var.enable_gateway_lakehouse_dns (default true).
 */

resource "null_resource" "gateway_lakehouse_dns" {
  count = var.enable_gateway_lakehouse_dns ? 1 : 0

  triggers = {
    gateway_ip              = "192.168.70.1"
    minio_name              = var.lakehouse_minio_dns_name
    minio_ips               = join(",", var.lakehouse_minio_ips)
    iceberg_name            = var.lakehouse_iceberg_dns_name
    iceberg_ips             = join(",", var.lakehouse_iceberg_ips)
    spark_master_name       = var.lakehouse_spark_master_dns_name
    spark_master_ips        = join(",", var.lakehouse_spark_master_ips)
    lakehouse_dns_overlay_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $marker  = '# lakehouse round-robin records managed by terraform/envs/foundation/role-overlay-gateway-lakehouse-dns.tf'

      $pairs = @(
        @{ name = '${var.lakehouse_minio_dns_name}';        ips = '${join(",", var.lakehouse_minio_ips)}' }
        @{ name = '${var.lakehouse_iceberg_dns_name}';       ips = '${join(",", var.lakehouse_iceberg_ips)}' }
        @{ name = '${var.lakehouse_spark_master_dns_name}';  ips = '${join(",", var.lakehouse_spark_master_ips)}' }
      )
      $hostsLines = @()
      foreach ($p in $pairs) {
        if ($p.ips) {
          foreach ($ip in ($p.ips -split ',')) { if ($ip.Trim()) { $hostsLines += "$($ip.Trim()) $($p.name)" } }
        }
      }
      $hostsBody = ($marker, ($hostsLines -join "`n"), "") -join "`n"
      $confBody  = ($marker, "addn-hosts=/etc/dnsmasq-lakehouse.hosts", "") -join "`n"

      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq-lakehouse.hosts && cat /etc/dnsmasq-lakehouse.hosts || true" 2>&1 | Out-String
      if ($existing.Trim() -eq $hostsBody.Trim()) {
        Write-Host "[gateway lakehouse-dns] round-robin records already current, no-op."
        exit 0
      }

      $hostsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($hostsBody))
      $confB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($confBody))
      $remote = @"
set -euo pipefail
echo '$hostsB64' | base64 -d | sudo tee /etc/dnsmasq-lakehouse.hosts > /dev/null
sudo chown root:root /etc/dnsmasq-lakehouse.hosts
sudo chmod 0644 /etc/dnsmasq-lakehouse.hosts
echo '$confB64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-lakehouse-dns.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-lakehouse-dns.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-lakehouse-dns.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- /etc/dnsmasq-lakehouse.hosts ---"
sudo cat /etc/dnsmasq-lakehouse.hosts
echo "--- resolving ${var.lakehouse_minio_dns_name} (expect all MinIO node IPs) ---"
dig +short ${var.lakehouse_minio_dns_name} @127.0.0.1
"@
      $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($remote -replace "`r`n","`n")))
      $output = ssh @sshOpts "$sshUser@$gw" "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[gateway lakehouse-dns] failed (rc=$rc)" }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@192.168.70.1" "sudo rm -f /etc/dnsmasq.d/foundation-lakehouse-dns.conf /etc/dnsmasq-lakehouse.hosts && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
