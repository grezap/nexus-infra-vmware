/*
 * role-overlay-dc-password-policy.tf -- Default Domain Password + Lockout Policy.
 *
 * Phase 0.C.4 layer. Sets the single domain-wide policy that applies to all
 * users (including the migrated `nexusadmin` and any future human/service
 * accounts) via Set-ADDefaultDomainPasswordPolicy.
 *
 * Why Default Domain Policy and not Fine-Grained Password Settings Objects
 * (PSO): one cohort right now (just `nexusadmin`); PSOs are the right tool
 * once we have multiple cohorts (humans vs service accounts vs break-glass) --
 * that's Phase 0.C.6+ when service accounts land.
 *
 * Reachability invariant (memory/feedback_lab_host_reachability.md):
 *   - LockoutThreshold defaults to 5 -- high enough that an automated probe
 *     loop hitting AD with a stale credential doesn't lock out `nexusadmin`
 *     mid-apply (which would fail SSH and RDP from the build host
 *     simultaneously, the exact reachability failure the rule prevents).
 *   - This overlay does NOT touch Windows Firewall, sshd_config, or RDP
 *     settings. Reachability is preserved.
 *
 * Defaults (NIST SP 800-63B-aligned, lab-pragmatic):
 *   - MinPasswordLength=12 -- matches existing bootstrap creds (NexusAdmin!1
 *     is 12 chars). Bump to 14 in Phase 0.D when Vault generates creds.
 *   - ComplexityEnabled=true -- domain default; keep.
 *   - LockoutThreshold=5 invalid attempts.
 *   - LockoutDuration=15 min.
 *   - LockoutObservationWindow=15 min.
 *   - MaxPasswordAge=0 -- modern NIST stance: rotate only on suspected
 *     compromise. Pre-Vault we have no automation to rotate cleanly.
 *   - MinPasswordAge=0 -- allow immediate change (break-glass scenarios).
 *   - PasswordHistoryCount=24 -- domain default.
 *   - ReversibleEncryptionEnabled=false -- domain default.
 *
 * Selective ops (memory/feedback_selective_provisioning.md):
 *   - var.enable_dc_password_policy (default true) gates the entire overlay.
 *   - Each setting is independently var-controlled.
 *
 * Idempotency: Get-ADDefaultDomainPasswordPolicy first, only Set- if any field
 * differs from the desired value. Re-applies are no-ops when state matches.
 */

resource "null_resource" "dc_password_policy" {
  count = var.enable_dc_password_policy ? 1 : 0

  triggers = {
    dc_verify_id              = null_resource.dc_nexus_verify[0].id
    min_password_length       = var.dc_password_min_length
    lockout_threshold         = var.dc_lockout_threshold
    lockout_duration_minutes  = var.dc_lockout_duration_minutes
    max_password_age_days     = var.dc_max_password_age_days
    min_password_age_days     = var.dc_min_password_age_days
    password_history_count    = var.dc_password_history_count
    password_policy_overlay_v = "3" # v3 = ship script via scp + powershell -File (was -EncodedCommand). At v=2 + MinPasswordLength=14 the encoded base64 was ~8 KB which exceeded cmd.exe's command-line limit; remote SSH returned "The command line is too long." but the retry loop's predicate (only matched connection-level failures) treated exit=1 as success, silently dropping the policy update. Per memory/feedback_windows_ssh_automation.md rule #2 (base64 transit has length limits) + memory/feedback_diagnose_before_rewriting.md (catch failure modes the retry loop doesn't classify). v2 = hoist `if`-as-expression for MaxPasswordAge=0/never out of inline string concat. v1 = initial implementation.
  }

  depends_on = [null_resource.dc_nexus_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip                    = '${local.dc_nexus_ip}'
      $minLen                = ${var.dc_password_min_length}
      $lockoutThreshold      = ${var.dc_lockout_threshold}
      $lockoutDuration       = ${var.dc_lockout_duration_minutes}
      $maxPasswordAge        = ${var.dc_max_password_age_days}
      $minPasswordAge        = ${var.dc_min_password_age_days}
      $passwordHistoryCount  = ${var.dc_password_history_count}

      Write-Host "[dc-password-policy] dispatching Set-ADDefaultDomainPasswordPolicy on $ip"

      # Idempotent: read current policy, compare; only Set- if any field
      # differs. AD stores Lockout/Age values as TimeSpans -- we compare in
      # minutes/days for human-friendly diff output.
      $remote = @"
        Import-Module ActiveDirectory;
        `$cur = Get-ADDefaultDomainPasswordPolicy;
        `$curMaxDays = if (`$cur.MaxPasswordAge.TotalDays -lt 1 -or `$cur.MaxPasswordAge.Ticks -eq 0) { 0 } else { [int]`$cur.MaxPasswordAge.TotalDays };
        `$curMinDays = [int]`$cur.MinPasswordAge.TotalDays;
        `$curLockMin = [int]`$cur.LockoutDuration.TotalMinutes;
        `$curObsMin  = [int]`$cur.LockoutObservationWindow.TotalMinutes;
        `$diffs = @();
        if (`$cur.MinPasswordLength -ne $minLen)             { `$diffs += "MinPasswordLength: `$(`$cur.MinPasswordLength) -> $minLen" };
        if (`$cur.LockoutThreshold -ne $lockoutThreshold)    { `$diffs += "LockoutThreshold: `$(`$cur.LockoutThreshold) -> $lockoutThreshold" };
        if (`$curLockMin -ne $lockoutDuration)               { `$diffs += "LockoutDuration: `$curLockMin min -> $lockoutDuration min" };
        if (`$curObsMin -ne $lockoutDuration)                { `$diffs += "LockoutObservationWindow: `$curObsMin min -> $lockoutDuration min" };
        if (`$curMaxDays -ne $maxPasswordAge)                { `$diffs += "MaxPasswordAge: `$curMaxDays days -> $maxPasswordAge days" };
        if (`$curMinDays -ne $minPasswordAge)                { `$diffs += "MinPasswordAge: `$curMinDays days -> $minPasswordAge days" };
        if (`$cur.PasswordHistoryCount -ne $passwordHistoryCount) { `$diffs += "PasswordHistoryCount: `$(`$cur.PasswordHistoryCount) -> $passwordHistoryCount" };
        if (-not `$cur.ComplexityEnabled)                    { `$diffs += "ComplexityEnabled: False -> True" };
        if (`$diffs.Count -eq 0) {
          Write-Output 'password policy already matches desired state, no-op';
        } else {
          Write-Output ('changing password policy: ' + (`$diffs -join '; '));
          `$lockoutSpan = New-TimeSpan -Minutes $lockoutDuration;
          # MaxPasswordAge=0 means "never expire" -- represented as a zero TimeSpan.
          # New-TimeSpan -Days 0 returns 00:00:00 which is what AD interprets as never.
          `$maxAgeSpan  = New-TimeSpan -Days $maxPasswordAge;
          `$minAgeSpan  = New-TimeSpan -Days $minPasswordAge;
          Set-ADDefaultDomainPasswordPolicy -Identity (Get-ADDomain).DistinguishedName ``
            -ComplexityEnabled `$true ``
            -MinPasswordLength $minLen ``
            -LockoutThreshold $lockoutThreshold ``
            -LockoutDuration `$lockoutSpan ``
            -LockoutObservationWindow `$lockoutSpan ``
            -MaxPasswordAge `$maxAgeSpan ``
            -MinPasswordAge `$minAgeSpan ``
            -PasswordHistoryCount $passwordHistoryCount ``
            -ReversibleEncryptionEnabled `$false;
          Write-Output 'password policy updated';
        };
        `$verify = Get-ADDefaultDomainPasswordPolicy;
        # Hoist if-as-expression to a separate statement -- Win PowerShell 5.1
        # (Server 2025 default) doesn't support `if` as an inline expression
        # inside a larger expression like 'foo' + (if ...). Compute the
        # MaxPasswordAge string first, then concatenate.
        `$maxAgeStr = if (`$verify.MaxPasswordAge.Ticks -eq 0) { '0 (never)' } else { ([int]`$verify.MaxPasswordAge.TotalDays).ToString() + 'd' };
        Write-Output ('verify: MinPasswordLength=' + `$verify.MinPasswordLength + ', LockoutThreshold=' + `$verify.LockoutThreshold + ', LockoutDuration=' + [int]`$verify.LockoutDuration.TotalMinutes + 'min, MaxPasswordAge=' + `$maxAgeStr)
"@
      # Ship as file (scp + powershell -File) instead of -EncodedCommand.
      # The encoded base64 of this script (UTF-16 + base64) crosses cmd.exe's
      # ~8 KB command-line limit when MinPasswordLength=14 is the target
      # (cmd.exe rejects with "The command line is too long.")  Per memory
      # feedback_windows_ssh_automation.md rule #2 + the LDAPS cert overlay's
      # canonical pattern, scp the script + run via powershell -File.
      $tmpDir          = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "nexus-pwd-policy-$(Get-Random)")
      $localScriptPath = Join-Path $tmpDir 'set-password-policy.ps1'
      $remoteScriptPath = 'C:/Windows/Temp/set-password-policy.ps1'
      Set-Content -Path $localScriptPath -Value $remote -Encoding UTF8

      $maxAttempts = 5
      $issued      = $false
      $sshOutput   = ''
      for ($i = 1; $i -le $maxAttempts; $i++) {
        # Stage the script on the DC first, then run it via -File. Tighten
        # the success predicate: ssh exit MUST be 0 AND output MUST contain
        # the verify marker. exit=1 alone (the prior false-positive case)
        # is now correctly classified as failure.
        scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $localScriptPath "nexusadmin@$${ip}:$remoteScriptPath" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
          Write-Host "[dc-password-policy] attempt $i scp failed (rc=$LASTEXITCODE), retrying..."
          Start-Sleep -Seconds 10
          continue
        }
        $sshOutput = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteScriptPath" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($rc -eq 0 -and $sshOutput -match 'verify: MinPasswordLength=') {
          Write-Host "[dc-password-policy] attempt $i succeeded (ssh exit=$rc)"
          Write-Host "[dc-password-policy] ssh output:`n$($sshOutput.Trim())"
          $issued = $true
          break
        }
        Write-Host "[dc-password-policy] attempt $i FAILED (rc=$rc): $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
      if (-not $issued) {
        throw "[dc-password-policy] all $maxAttempts attempts failed. Last output: $sshOutput"
      }
    PWSH
  }
}
