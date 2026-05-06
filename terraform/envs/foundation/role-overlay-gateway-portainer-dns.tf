/*
 * role-overlay-gateway-portainer-dns.tf -- Phase 0.E.4c
 *
 * Adds a multi-A DNS record for `portainer.nexus.lab` to nexus-gateway's
 * dnsmasq, mapping it to the 3 swarm-manager VMnet11 IPs (.111-.113).
 *
 * dnsmasq's `host-record=name,IP[,IP][,IP]` registers ALL three IPs with
 * the same hostname; the response includes all 3 A records, and standard
 * DNS clients round-robin or rotate through them. Combined with Docker
 * Swarm's routing mesh (any manager IP routes traffic to the active
 * Portainer Server replica), a single `https://portainer.nexus.lab:9443`
 * URL works regardless of which manager is currently scheduled.
 *
 * Why dnsmasq + multi-A (not Traefik / nginx reverse proxy):
 *   - Lab-pragmatic: one config line on the existing edge router; no new
 *     VM, no new TLS termination layer, no new ingress controller.
 *   - The TLS cert (issued by 0.E.4b's portainer-server PKI role) covers
 *     all 3 manager IPs as IP SANs + the `portainer.nexus.lab` CN, so
 *     validation works whichever IP the client picks.
 *   - Production would put a dedicated ingress controller in front;
 *     documented as a deviation in 0.E.5 close-out canon.
 *
 * Mirrors role-overlay-gateway-dns.tf shape (idempotent via marker
 * comment + skip-if-present).
 *
 * Selective ops: var.enable_gateway_portainer_dns (default true).
 */

resource "null_resource" "gateway_portainer_dns" {
  count = var.enable_gateway_portainer_dns ? 1 : 0

  triggers = {
    gateway_ip                = "192.168.70.1"
    portainer_hostname        = var.portainer_dns_name
    manager_ips               = join(",", var.portainer_dns_manager_ips)
    portainer_dns_overlay_v   = "1"
  }

  # Decoupled from dc_nexus_wait_promoted (this DNS entry is purely a
  # client-side dnsmasq host-record; it doesn't depend on AD DS).
  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw          = '192.168.70.1'
      $sshUser     = 'nexusadmin'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $hostname    = '${var.portainer_dns_name}'
      $managerIps  = '${join(",", var.portainer_dns_manager_ips)}'
      $marker      = '# portainer.nexus.lab multi-A managed by terraform/envs/foundation/role-overlay-gateway-portainer-dns.tf'

      # Idempotent insert: skip if marker is already in dnsmasq.d/.
      $existing = ssh @sshOpts "$sshUser@$gw" "test -f /etc/dnsmasq.d/foundation-portainer.conf && cat /etc/dnsmasq.d/foundation-portainer.conf || true" 2>&1 | Out-String
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway portainer-dns] $hostname multi-A already present, no-op."
        exit 0
      }

      # dnsmasq host-record syntax: `host-record=NAME,IP[,IP]...` -- single
      # line for multiple IPs of the same hostname. All 3 IPs are returned
      # in the A-record response; standard resolvers round-robin/rotate.
      $confLines = @(
        $marker
        "host-record=$hostname,$managerIps"
        ""
      ) -join "`n"

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($confLines))
      $remote = @"
set -euo pipefail
echo '$b64' | base64 -d | sudo tee /etc/dnsmasq.d/foundation-portainer.conf > /dev/null
sudo chown root:root /etc/dnsmasq.d/foundation-portainer.conf
sudo chmod 0644 /etc/dnsmasq.d/foundation-portainer.conf
sudo systemctl restart dnsmasq
sleep 1
sudo systemctl is-active dnsmasq
echo "--- foundation-portainer.conf ---"
sudo cat /etc/dnsmasq.d/foundation-portainer.conf
echo "--- dig $hostname ---"
dig +short @127.0.0.1 $hostname || true
"@
      $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($remote -replace "`r`n", "`n")))
      $output = ssh @sshOpts "$sshUser@$gw" "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[gateway portainer-dns] failed (rc=$rc)"
      }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@192.168.70.1" "sudo rm -f /etc/dnsmasq.d/foundation-portainer.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
