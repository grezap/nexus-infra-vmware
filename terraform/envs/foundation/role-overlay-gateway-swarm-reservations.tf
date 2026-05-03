/*
 * role-overlay-gateway-swarm-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning the 3+3 Swarm cluster MACs to canonical VMnet11 IPs.
 *
 * Phase 0.E.1 layer. Per nexus-platform-plan/docs/infra/vms.yaml lines 182-191,
 * the Swarm cluster nodes must come up at canonical IPs:
 *   swarm-manager-1 -> 192.168.70.111
 *   swarm-manager-2 -> 192.168.70.112
 *   swarm-manager-3 -> 192.168.70.113
 *   swarm-worker-1  -> 192.168.70.131
 *   swarm-worker-2  -> 192.168.70.132
 *   swarm-worker-3  -> 192.168.70.133
 *
 * nexus-gateway's dnsmasq dynamic DHCP pool is .200-.250; dnsmasq honors
 * `dhcp-host=<MAC>,<IP>,<hostname>` reservations regardless of whether the
 * IP falls inside dhcp-range, so we add per-MAC reservations here without
 * modifying the gateway template.
 *
 * Lives in foundation env (NOT in nexus-infra-swarm-nomad/) because the
 * gateway is foundation's responsibility -- consolidating gateway-state
 * ownership in one repo avoids two terraform repos racing on the same
 * /etc/dnsmasq.d/ contents. The swarm-nomad env's clones consume the
 * pinned IPs but don't write the reservations.
 *
 * Default `enable_swarm_dhcp_reservations = true` per memory/
 * feedback_terraform_partial_apply_destroys_resources.md (steady state =
 * lab has the swarm tier active; partial-apply silent destruction is the
 * gotcha to avoid).
 *
 * Mirrors role-overlay-gateway-vault-reservations.tf shape:
 *   - SSH to gateway, write /etc/dnsmasq.d/foundation-swarm-reservations.conf
 *   - Marker comment includes overlay version for idempotent re-apply
 *   - systemctl restart dnsmasq (NOT reload; reload doesn't re-read
 *     dhcp-host entries reliably)
 *   - Destroy-time provisioner removes the conf + restarts
 */

resource "null_resource" "gateway_swarm_reservations" {
  count = var.enable_swarm_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip           = "192.168.70.1"
    mac_mgr_1            = var.mac_swarm_manager_1_primary
    mac_mgr_2            = var.mac_swarm_manager_2_primary
    mac_mgr_3            = var.mac_swarm_manager_3_primary
    mac_wrk_1            = var.mac_swarm_worker_1_primary
    mac_wrk_2            = var.mac_swarm_worker_2_primary
    mac_wrk_3            = var.mac_swarm_worker_3_primary
    swarm_reservations_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $mac_m1  = '${var.mac_swarm_manager_1_primary}'
      $mac_m2  = '${var.mac_swarm_manager_2_primary}'
      $mac_m3  = '${var.mac_swarm_manager_3_primary}'
      $mac_w1  = '${var.mac_swarm_worker_1_primary}'
      $mac_w2  = '${var.mac_swarm_worker_2_primary}'
      $mac_w3  = '${var.mac_swarm_worker_3_primary}'
      $marker  = '# Swarm cluster dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-swarm-reservations.tf v1'

      # Idempotent insert: marker matches v1 specifically; future v2 (e.g.
      # adds Portainer node) won't false-match here.
      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-swarm-reservations.conf && cat /etc/dnsmasq.d/foundation-swarm-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway swarm-reservations] v1 reservations already present, no-op."
        exit 0
      }

      # Per nexus-platform-plan/docs/infra/vms.yaml lines 186-191.
      $confLines = @(
        $marker
        "dhcp-host=$mac_m1,192.168.70.111,swarm-manager-1"
        "dhcp-host=$mac_m2,192.168.70.112,swarm-manager-2"
        "dhcp-host=$mac_m3,192.168.70.113,swarm-manager-3"
        "dhcp-host=$mac_w1,192.168.70.131,swarm-worker-1"
        "dhcp-host=$mac_w2,192.168.70.132,swarm-worker-2"
        "dhcp-host=$mac_w3,192.168.70.133,swarm-worker-3"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-swarm-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway swarm-reservations] writing dhcp-host reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway swarm-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway swarm-reservations] reservations live: managers .111-.113, workers .131-.133"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway swarm-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-swarm-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
