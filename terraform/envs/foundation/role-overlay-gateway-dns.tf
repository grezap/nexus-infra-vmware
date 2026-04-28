/*
 * role-overlay-gateway-dns.tf -- env-scoped dnsmasq forward so VMnet11 hosts can resolve nexus.lab.
 *
 * The 0.B.1 nexus-gateway template's dnsmasq.conf intentionally has no per-domain
 * forwards baked in -- DC promotion is an env-time concern, and pinning the forward
 * into the gateway template would couple the always-on edge router to the foundation
 * env's specific layout. Instead, this overlay edits the running gateway's dnsmasq
 * config at apply-time and reloads the service.
 *
 * Per memory/feedback_selective_provisioning.md:
 *   - Keep 0.B.* templates frozen (no rebuild needed for env-time DNS layout changes).
 *   - var.enable_gateway_dns_forward (default true) gates the entire overlay.
 *   - Independently `-target`-able for ad-hoc iteration.
 *
 * Idempotency:
 *   - The marker line (`# nexus.lab forward managed by terraform/envs/foundation`) lets
 *     re-applies detect existing config and skip without duplicating entries.
 *   - The destroy-time provisioner removes the marked block + reloads dnsmasq, so
 *     `terraform destroy` (or destroying just this resource) cleanly reverts.
 *
 * Trust:
 *   - SSH passes through ssh-agent / ~/.ssh/config (handbook §0.4).
 *   - The forward is one line: `server=/${var.ad_domain}/${dc-nexus-ip}` -- queries for
 *     anything under nexus.lab go to dc-nexus's DNS service; everything else falls
 *     through to dnsmasq's existing upstream resolvers.
 */

resource "null_resource" "gateway_dns_forward" {
  count = var.enable_gateway_dns_forward ? 1 : 0

  triggers = {
    gateway_ip    = "192.168.70.1"
    dc_nexus_ip   = "192.168.70.240"
    ad_domain     = var.ad_domain
    dns_overlay_v = "2" # v2 = systemctl restart (not reload) so DNS cache flushes; v1 cached NXDOMAIN survived the SIGHUP reload
  }

  # The DNS forward only matters once dc-nexus is actually serving DNS. Wait for the
  # post-promotion verify step before writing the gateway config -- otherwise the
  # forward points at an IP that doesn't yet have a DNS service.
  depends_on = [null_resource.dc_nexus_wait_promoted]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw     = '192.168.70.1'
      $dc_ip  = '192.168.70.240'
      $domain = '${var.ad_domain}'
      $marker = '# nexus.lab forward managed by terraform/envs/foundation/role-overlay-gateway-dns.tf'

      # Idempotent insert: skip if the marker is already in dnsmasq.d/.
      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-nexus-lab.conf && cat /etc/dnsmasq.d/foundation-nexus-lab.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway dns] forward for $domain already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "server=/$domain/$dc_ip"
        ""
      ) -join "`n"

      # Drop the conf file via stdin (sudo tee), then RESTART dnsmasq.
      #
      # systemctl reload (SIGHUP) re-reads conf-dir but DOES NOT flush the DNS
      # cache. Lesson learned 2026-04-29: when the gateway was queried for
      # nexus.lab BEFORE the forward was added, dnsmasq cached the
      # DNSSEC-signed NXDOMAIN from public resolvers (1.1.1.1, 1.0.0.1, 9.9.9.9).
      # SIGHUP loaded the new server=/nexus.lab/<dc-ip> rule but the cached
      # NXDOMAIN kept serving until cache TTL expired. systemctl restart drops
      # the cache as part of process restart, so the forward is live immediately.
      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-nexus-lab.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway dns] writing /etc/dnsmasq.d/foundation-nexus-lab.conf + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway dns] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway dns] $domain forward live: queries -> $dc_ip"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway dns] removing /etc/dnsmasq.d/foundation-nexus-lab.conf + reloading dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-nexus-lab.conf && sudo systemctl reload dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
