/*
 * role-overlay-dc-reverse-dns.tf -- reverse DNS zone for VMnet11 (192.168.70.0/24)
 * + PTR records for dc-nexus (.240) and nexus-jumpbox (.241).
 *
 * Phase 0.C.4 layer. Adds AD-integrated reverse zone `70.168.192.in-addr.arpa.`
 * to dc-nexus's DNS server (already running as part of Install-ADDSForest's
 * InstallDns flag). PTR records improve log readability for AD operations and
 * any tool that does reverse lookups (Kerberos error messages reference FQDNs;
 * sshd's `UseDNS` lookups; security event log reverses).
 *
 * Scope: 192.168.70.0/24 only (VMnet11). VMnet10 / 10.0.70.0/24 (build-host
 * LAN) is intentionally NOT covered -- nexus-gateway only forwards from VMnet11
 * and dc-nexus's DNS server isn't authoritative outside the lab subnet.
 *
 * Reachability invariant (memory/feedback_lab_host_reachability.md):
 *   - This overlay only adds DNS records. It does NOT touch Windows Firewall,
 *     sshd_config, or RDP settings. SSH and RDP from the build host are
 *     unaffected.
 *
 * Selective ops (memory/feedback_selective_provisioning.md):
 *   - var.enable_dc_reverse_dns (default true) gates the entire overlay.
 *
 * Idempotency:
 *   - Get-DnsServerZone -Name '70.168.192.in-addr.arpa' before Add-DnsServerPrimaryZone.
 *   - Get-DnsServerResourceRecord -RRType Ptr per record before Add-.
 *   - Re-applies are no-ops when zone + records exist.
 *
 * jumpbox PTR is conditionally added: if enable_jumpbox_domain_join=false the
 * jumpbox isn't on the network as a domain member, but its DHCP lease at .241
 * still exists -- we add the PTR unconditionally because the static MAC pins
 * the IP (and the PTR is harmless if the box is later workgroup-only).
 */

locals {
  # Reverse DNS zone for VMnet11 (192.168.70.0/24). Hardcoded -- the lab subnet
  # is fixed by the nexus-gateway template (Phase 0.B.1) and dnsmasq DHCP scope.
  reverse_zone_name = "70.168.192.in-addr.arpa"
}

resource "null_resource" "dc_reverse_dns" {
  count = var.enable_dc_reverse_dns ? 1 : 0

  triggers = {
    dc_verify_id          = null_resource.dc_nexus_verify[0].id
    reverse_zone          = local.reverse_zone_name
    reverse_dns_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip               = '${local.dc_nexus_ip}'
      $reverseZone      = '${local.reverse_zone_name}'
      $domain           = '${local.ad_domain}'
      $dcHostname       = '${local.dc_nexus_hostname}'
      $jumpboxHostname  = '${local.jumpbox_hostname}'
      $dcLastOctet      = '240'
      $jumpboxLastOctet = '241'

      Write-Host "[dc-reverse-dns] dispatching reverse zone + PTR records on $ip"

      $remote = @"
        Import-Module DnsServer;
        `$zone = Get-DnsServerZone -Name '$reverseZone' -ErrorAction SilentlyContinue;
        if (-not `$zone) {
          Add-DnsServerPrimaryZone -NetworkId '192.168.70.0/24' -ReplicationScope 'Domain' -DynamicUpdate 'Secure';
          Write-Output 'reverse zone $reverseZone created';
        } else {
          Write-Output 'reverse zone $reverseZone already present';
        };
        `$dcPtr = Get-DnsServerResourceRecord -ZoneName '$reverseZone' -Name '$dcLastOctet' -RRType Ptr -ErrorAction SilentlyContinue;
        if (-not `$dcPtr) {
          Add-DnsServerResourceRecordPtr -ZoneName '$reverseZone' -Name '$dcLastOctet' -PtrDomainName '$dcHostname.$domain.';
          Write-Output 'PTR added: $dcLastOctet -> $dcHostname.$domain.';
        } else {
          Write-Output 'PTR already present: $dcLastOctet';
        };
        `$jbPtr = Get-DnsServerResourceRecord -ZoneName '$reverseZone' -Name '$jumpboxLastOctet' -RRType Ptr -ErrorAction SilentlyContinue;
        if (-not `$jbPtr) {
          Add-DnsServerResourceRecordPtr -ZoneName '$reverseZone' -Name '$jumpboxLastOctet' -PtrDomainName '$jumpboxHostname.$domain.';
          Write-Output 'PTR added: $jumpboxLastOctet -> $jumpboxHostname.$domain.';
        } else {
          Write-Output 'PTR already present: $jumpboxLastOctet';
        };
        Write-Output '--- verify ---';
        Get-DnsServerResourceRecord -ZoneName '$reverseZone' -RRType Ptr | Format-Table HostName, RecordData, Timestamp -AutoSize | Out-String
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      $maxAttempts = 5
      $issued = $false
      for ($i = 1; $i -le $maxAttempts; $i++) {
        $sshOutput = ssh -o ConnectTimeout=15 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($sshOutput -notmatch "Connection (timed out|refused)" -and $sshOutput -notmatch "port 22:") {
          Write-Host "[dc-reverse-dns] attempt $i succeeded (ssh exit=$rc)"
          if ($sshOutput.Trim()) { Write-Host "[dc-reverse-dns] ssh output:`n$($sshOutput.Trim())" }
          $issued = $true
          break
        }
        Write-Host "[dc-reverse-dns] attempt $i failed: $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      if (-not $issued) {
        throw "[dc-reverse-dns] all $maxAttempts attempts failed. Last output: $sshOutput"
      }
    PWSH
  }
}
