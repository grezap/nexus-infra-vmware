/*
 * role-overlay-dc-time.tf -- W32Time PDC authoritative configuration on dc-nexus.
 *
 * Phase 0.C.4 layer. Configures dc-nexus (the PDC for nexus.lab) to be the
 * authoritative time source for the domain, syncing from public NTP peers via
 * the gateway's NAT path. All domain members (jumpbox + future fleet) inherit
 * time from the PDC by default -- no client-side configuration needed.
 *
 * Defaults (var.dc_time_external_peers): time.cloudflare.com, time.nist.gov,
 * pool.ntp.org, time.windows.com -- four peers, mixed providers.
 *
 * Why public peers and not the gateway: nexus-gateway runs chrony as a CLIENT
 * (per packer/_shared/ansible/roles/nexus_network); whether it exposes server
 * mode externally is unverified. Pivoting dc-nexus to sync from 192.168.70.1
 * (gateway-as-NTP-server) is a cleaner enterprise pattern but requires an
 * audit + potentially a gateway template change -- separate ticket post-0.C.4.
 *
 * Reachability invariant (memory/feedback_lab_host_reachability.md):
 *   - W32Time configuration only affects outbound NTP (UDP/123) from dc-nexus.
 *     It does NOT touch Windows Firewall inbound rules, sshd_config, or RDP
 *     settings. SSH and RDP from the build host are unaffected.
 *
 * Selective ops (memory/feedback_selective_provisioning.md):
 *   - var.enable_dc_time_authoritative (default true) gates the entire overlay.
 *   - var.dc_time_external_peers controls the peer list (string of comma-
 *     separated NTP host:port entries; w32tm wants space-separated, we
 *     translate).
 *
 * Idempotency:
 *   - `w32tm /query /configuration` returns the current NtpServer + Type. We
 *     compare both against the desired values; only reconfigure if either
 *     differs. Re-applies are no-ops when state matches.
 *
 * Commands applied (when reconfiguring):
 *   w32tm /config /manualpeerlist:"<peer1>,0x8 <peer2>,0x8 ..." /syncfromflags:MANUAL /reliable:YES /update
 *   Restart-Service w32time
 *   w32tm /resync /force
 *
 * The 0x8 flag = SpecialInterval (use the configured poll interval) -- the
 * recommended PDC pattern per Microsoft KB 939322 (Time service configuration
 * on a PDC emulator).
 */

resource "null_resource" "dc_time_authoritative" {
  count = var.enable_dc_time_authoritative ? 1 : 0

  triggers = {
    dc_verify_id   = null_resource.dc_nexus_verify[0].id
    external_peers = var.dc_time_external_peers
    time_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip       = '${local.dc_nexus_ip}'
      $peersCsv = '${var.dc_time_external_peers}'

      # Translate "a,b,c,d" -> "a,0x8 b,0x8 c,0x8 d,0x8" (w32tm peer list format).
      $peerList = (($peersCsv -split ',') | ForEach-Object { "$($_.Trim()),0x8" }) -join ' '

      Write-Host "[dc-time] dispatching w32tm config on $ip; peers: $peerList"

      # Idempotency: parse current w32tm config; reconfigure only if NtpServer
      # or Type differs. w32tm /query /configuration emits ini-style sections;
      # we extract the [TimeProviders\NtpClient] block.
      $remote = @"
        `$cur = (w32tm /query /configuration) -join "``n";
        `$curServers = '';
        `$curType    = '';
        if (`$cur -match 'NtpServer:\s*(.+?)\s*\(') { `$curServers = `$matches[1].Trim() };
        if (`$cur -match 'Type:\s*(\S+)\s*\(')      { `$curType    = `$matches[1].Trim() };
        `$desiredServers = '$peerList';
        `$desiredType    = 'NTP';
        if (`$curServers -eq `$desiredServers -and `$curType -eq `$desiredType) {
          Write-Output ('w32tm config already matches: NtpServer=' + `$curServers + ', Type=' + `$curType + ', no-op');
        } else {
          Write-Output ('reconfiguring w32tm: NtpServer ' + `$curServers + ' -> ' + `$desiredServers + '; Type ' + `$curType + ' -> ' + `$desiredType);
          w32tm /config /manualpeerlist:"`$desiredServers" /syncfromflags:MANUAL /reliable:YES /update | Out-Null;
          Restart-Service w32time;
          Start-Sleep -Seconds 3;
          w32tm /resync /force | Out-Null;
        };
        Write-Output '--- verify ---';
        w32tm /query /configuration | Select-String -Pattern 'NtpServer|^Type|AnnounceFlags';
        Write-Output '--- status ---';
        w32tm /query /status | Select-String -Pattern 'Source|Stratum|Last Successful'
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      $maxAttempts = 5
      $issued = $false
      for ($i = 1; $i -le $maxAttempts; $i++) {
        $sshOutput = ssh -o ConnectTimeout=15 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($sshOutput -notmatch "Connection (timed out|refused)" -and $sshOutput -notmatch "port 22:") {
          Write-Host "[dc-time] attempt $i succeeded (ssh exit=$rc)"
          if ($sshOutput.Trim()) { Write-Host "[dc-time] ssh output:`n$($sshOutput.Trim())" }
          $issued = $true
          break
        }
        Write-Host "[dc-time] attempt $i failed: $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      if (-not $issued) {
        throw "[dc-time] all $maxAttempts attempts failed. Last output: $sshOutput"
      }
    PWSH
  }
}
