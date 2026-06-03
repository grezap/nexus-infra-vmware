/*
 * role-overlay-gateway-citus-dns.tf -- Phase 0.P
 *
 * Adds 3 single-A DNS host-records on nexus-gateway's dnsmasq for the Citus
 * VRRP VIP front doors (ADR-0042):
 *   - coord.citus.nexus.lab   -> .211   (coordinator group VIP; client endpoint)
 *   - worker1.citus.nexus.lab -> .212   (worker-group-1 VIP; pg_dist_node entry)
 *   - worker2.citus.nexus.lab -> .213   (worker-group-2 VIP; pg_dist_node entry)
 *
 * Unlike the analytics round-robin names (multiple A records per name, served
 * from an addn-hosts file), these are SINGLE-IP names -- each maps to exactly
 * one keepalived-floated VIP. dnsmasq's `host-record=name,IP` is the right
 * primitive here (it keeps one IPv4 per name, which is exactly what a VIP is).
 * The VIP itself moves between the group's two PG nodes on Patroni failover;
 * the DNS name stays constant, and the per-node PG cert carries the VIP IP-SAN
 * so verify-full validates whichever leader currently holds it.
 *
 * Why a name (not just the raw VIP) for the worker registration: the
 * coordinator registers workers in pg_dist_node by the VIP, and the demo +
 * smoke address the coordinator by coord.citus.nexus.lab; resolvable names make
 * the topology legible + let clients use a stable hostname.
 *
 * Selective ops: var.enable_gateway_citus_dns (default true).
 */

resource "null_resource" "gateway_citus_dns" {
  count = var.enable_gateway_citus_dns ? 1 : 0

  triggers = {
    gateway_ip          = "192.168.70.1"
    coord_vip           = var.citus_coordinator_vip
    worker1_vip         = var.citus_worker1_vip
    worker2_vip         = var.citus_worker2_vip
    citus_dns_overlay_v = "1" # v1 (0.P) = 3 single-A VIP host-records (coord/worker1/worker2).
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw       = '192.168.70.1'
      $sshUser  = 'nexusadmin'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $coordVip = '${var.citus_coordinator_vip}'
      $w1Vip    = '${var.citus_worker1_vip}'
      $w2Vip    = '${var.citus_worker2_vip}'
      $marker   = '# citus VIP host-records managed by terraform/envs/foundation/role-overlay-gateway-citus-dns.tf v1'

      $confBody = @(
        $marker
        "host-record=coord.citus.nexus.lab,$coordVip"
        "host-record=worker1.citus.nexus.lab,$w1Vip"
        "host-record=worker2.citus.nexus.lab,$w2Vip"
        ""
      ) -join "`n"

      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq.d/foundation-citus-dns.conf && cat /etc/dnsmasq.d/foundation-citus-dns.conf || true" 2>&1 | Out-String
      if ($existing.Trim() -eq $confBody.Trim()) {
        Write-Host "[gateway citus-dns] VIP host-records already current, no-op."
        exit 0
      }

      $confB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($confBody -replace "`r`n","`n")))
      $remote = @"
set -euo pipefail
echo '$confB64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-citus-dns.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-citus-dns.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-citus-dns.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- resolving coord.citus.nexus.lab (expect $coordVip) ---"
dig +short coord.citus.nexus.lab @127.0.0.1
echo "--- resolving worker1.citus.nexus.lab (expect $w1Vip) ---"
dig +short worker1.citus.nexus.lab @127.0.0.1
echo "--- resolving worker2.citus.nexus.lab (expect $w2Vip) ---"
dig +short worker2.citus.nexus.lab @127.0.0.1
"@
      $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($remote -replace "`r`n","`n")))
      Write-Host "[gateway citus-dns] writing 3 VIP host-records (coord/worker1/worker2) + restarting dnsmasq..."
      $output = ssh @sshOpts "$sshUser@$gw" "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[gateway citus-dns] failed (rc=$rc)" }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "nexusadmin@192.168.70.1" "sudo rm -f /etc/dnsmasq.d/foundation-citus-dns.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
