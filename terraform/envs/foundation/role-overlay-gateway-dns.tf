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
    dns_overlay_v = "7" # v7 = `rebind-domain-ok=/<domain>/` -- the actual fix. The block was NEVER DNSSEC; gateway dnsmasq has `stop-dns-rebind` from 0.B.1, which blocks DNS responses where any domain (treated as "public") resolves to a private IP. Our internal nexus.lab → 192.168.70.240 trips the filter. journal: "possible DNS-rebind attack detected". EDE 15 Blocked = server-policy block, not DNSSEC. v1-v6 chased the wrong root cause. v7 drops the bogus `dnssec-check-unsigned=no` from v6.
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

      # Three-line forward + DNSSEC-bypass for the AD DS internal zone:
      #
      #   server=/nexus.lab/<dc-ip>           Forward all queries for nexus.lab
      #                                       (and subdomains incl. _msdcs.) to
      #                                       the DC's DNS service.
      #   server=/_msdcs.nexus.lab/<dc-ip>    Belt-and-suspenders explicit forward
      #                                       for AD's DC Locator zone -- dnsmasq
      #                                       subdomain matching already covers
      #                                       this, but it's the standard pattern
      #                                       and no-op if redundant.
      #   domain-insecure=/nexus.lab/         Bypass DNSSEC validation for this
      #                                       zone. Gateway dnsmasq runs with
      #                                       `dnssec-check-unsigned`, which
      #                                       requires the parent zone (`.lab`)
      #                                       to prove that nexus.lab is
      #                                       intentionally unsigned. The .lab
      #                                       TLD's DNSSEC chain has no
      #                                       delegation record for our internal
      #                                       nexus.lab, so dnsmasq returns
      #                                       SERVFAIL on A-record lookups even
      #                                       though SRV lookups (with their
      #                                       additional-section glue) appear to
      #                                       work. Add-Computer needs A-record
      #                                       resolution of dc-nexus.nexus.lab,
      #                                       which fails without this directive.
      #                                       Discovered 2026-04-29 during
      #                                       Phase 0.C.3 jumpbox domain-join.
      # Two-line conf: forward + DNS-rebind allowlist for our internal AD zone.
      #
      #   server=/<domain>/<dc-ip>      Forward all queries for <domain> (and
      #                                 subdomains incl. _msdcs.<domain>) to
      #                                 the DC's DNS service. dnsmasq's `/X/`
      #                                 forward matches subdomains by default.
      #
      #   rebind-domain-ok=/<domain>/   Bypass dnsmasq's `stop-dns-rebind`
      #                                 protection for this specific zone.
      #                                 The gateway's main dnsmasq.conf
      #                                 (Phase 0.B.1) enables stop-dns-rebind
      #                                 to block DNS responses that resolve
      #                                 "public" domains to private IPs (a
      #                                 well-known DNS-rebinding attack
      #                                 mitigation). Our internal nexus.lab
      #                                 isn't recognized as "private" and
      #                                 resolves to 192.168.70.240 (RFC1918
      #                                 space), so dnsmasq blocks the answer
      #                                 with "possible DNS-rebind attack
      #                                 detected" (visible in journalctl) and
      #                                 returns EDE 15 Blocked. SRV lookups
      #                                 still appeared to work via additional-
      #                                 section glue, but A-record lookups
      #                                 (which Add-Computer needs to find
      #                                 dc-nexus.<domain>) fail.
      #                                 `rebind-domain-ok=/<domain>/` is a
      #                                 per-zone allowlist that keeps
      #                                 stop-dns-rebind active for everything
      #                                 else.
      #
      # Discovered 2026-04-29 during Phase 0.C.3 jumpbox domain-join.
      # v1-v6 chased a DNSSEC theory; the journal `possible DNS-rebind attack
      # detected` was the real signal. EDE 15 Blocked = server-policy block,
      # not DNSSEC.
      $confLines = @(
        $marker
        "server=/$domain/$dc_ip"
        "rebind-domain-ok=/$domain/"
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
