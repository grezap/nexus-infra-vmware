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
    password_policy_overlay_v = "2" # v2 = hoist `if`-as-expression for MaxPasswordAge=0/never out of inline string concat (Win PS 5.1 doesn't support `if` as expression inside larger expressions, only as RHS of assignment); also moved $maxAgeSpan if-then to a pre-computed value. Cosmetic only -- v1 set the policy correctly but emitted a parse error on the verify line. v1 = initial implementation.
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
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      $maxAttempts = 5
      $issued = $false
      for ($i = 1; $i -le $maxAttempts; $i++) {
        $sshOutput = ssh -o ConnectTimeout=15 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($sshOutput -notmatch "Connection (timed out|refused)" -and $sshOutput -notmatch "port 22:") {
          Write-Host "[dc-password-policy] attempt $i succeeded (ssh exit=$rc)"
          if ($sshOutput.Trim()) { Write-Host "[dc-password-policy] ssh output:`n$($sshOutput.Trim())" }
          $issued = $true
          break
        }
        Write-Host "[dc-password-policy] attempt $i failed: $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      if (-not $issued) {
        throw "[dc-password-policy] all $maxAttempts attempts failed. Last output: $sshOutput"
      }
    PWSH
  }
}
