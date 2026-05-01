/*
 * role-overlay-dc-rotate-bootstrap-creds.tf -- Phase 0.D.5 step 1/5
 *
 * KV -> AD sync for the bootstrap credentials that 0.D.4 migrated to
 * Vault KV:
 *   - domain Administrator        (Set-ADAccountPassword)
 *   - nexusadmin                  (Set-ADAccountPassword)
 *
 * NOT auto-rotated by this overlay (canon at 0.D.5 close-out):
 *   - DSRM password (ntdsutil "set dsrm password" / "reset password on
 *     server null"). Empirical finding 2026-05-02: ntdsutil's password
 *     prompt uses console-mode read APIs (ReadConsole / GetConsoleMode)
 *     that fail under SSH / redirected stdin with WIN32 Error Code 0x1
 *     (ERROR_INVALID_FUNCTION). The SSH session is elevated (verified
 *     via `whoami /priv` showing SeDebugPrivilege etc.) and ntdsutil
 *     accepts subcommands as argv, but the password input itself
 *     cannot be delivered via pipe. This is a structural Windows
 *     limitation, similar to other entries in
 *     memory/feedback_windows_ssh_automation.md. Manual rotation
 *     procedure documented in docs/handbook.md s 1k.1.
 *     KV path nexus/foundation/dc-nexus/dsrm remains the canonical
 *     store of "what DSRM SHOULD be set to"; operators sync to live
 *     DC manually via RDP + ntdsutil console as a quarterly ops task.
 *
 * Why this overlay exists: dc_nexus_promote runs ONCE at forest-create
 * time and is idempotent (Get-ADDomain -> if forest exists, exit 0).
 * After the forest is up, rotating Vault KV doesn't propagate to AD
 * unless something pushes the new value. This overlay is that something
 * for Administrator + nexusadmin (the two AD-side identities that
 * Set-ADAccountPassword can update over a non-interactive SSH session).
 *
 * Trigger pattern: sha256(dsrm + admin + nexusadmin) -- when ANY of the
 * three Vault KV values change, the hash changes, the resource is
 * replaced. The dsrm component stays in the hash for change detection
 * but is NOT pushed to AD by the overlay (manual ops task per above).
 * Idempotent on first apply (KV values match what dc_nexus_promote set
 * during forest creation).
 *
 * Order vs dc_password_policy: this overlay depends_on dc_password_policy
 * so MinPasswordLength=14 is in place before any rotation. Vault's
 * nexus-ad-rotated policy generates 24-char pwds; foundation's seed
 * defaults are >=14 chars; so the policy-check on rotation never fails.
 *
 * NOT in scope: rotating svc-vault-ldap, svc-vault-smoke, svc-demo-rotated.
 * Those are managed by Vault's secrets/ldap engine OR by the foundation
 * env's bind/smoke overlays' direct-to-KV writeback (0.D.4). They're
 * already on Vault-rotated cadences.
 *
 * Selective ops: enable_dc_promotion AND enable_vault_kv_creds AND
 *                enable_dc_rotate_bootstrap_creds.
 *
 * Reachability invariant (per memory/feedback_lab_host_reachability.md):
 * pure AD password operations on dc-nexus. No Windows Firewall or sshd
 * config changes. SSH/22 + RDP/3389 from build host stay intact.
 */

resource "null_resource" "dc_rotate_bootstrap_creds" {
  count = var.enable_dc_promotion && var.enable_vault_kv_creds && var.enable_dc_rotate_bootstrap_creds ? 1 : 0

  triggers = {
    dc_verify_id     = null_resource.dc_nexus_verify[0].id
    policy_id        = length(null_resource.dc_password_policy) > 0 ? null_resource.dc_password_policy[0].id : "disabled"
    creds_hash       = sha256("${local.foundation_creds.dsrm}|${local.foundation_creds.local_administrator}|${local.foundation_creds.nexusadmin}")
    min_len_required = var.dc_password_min_length
    rotate_overlay_v = "4" # v4 = drop DSRM auto-rotation entirely (ntdsutil console-mode reads fail under SSH; manual ops task). Administrator + nexusadmin still rotated. v3 = ntdsutil via stdin (still failed -- console-mode read API). v2 = ship as file. v1 = -EncodedCommand.
  }

  depends_on = [null_resource.dc_nexus_verify, null_resource.dc_password_policy]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip            = '${local.dc_nexus_ip}'
      $dsrmPwd       = '${local.foundation_creds.dsrm}'
      $adminPwd      = '${local.foundation_creds.local_administrator}'
      $nexusadminPwd = '${local.foundation_creds.nexusadmin}'
      $minLen        = ${var.dc_password_min_length}

      Write-Host "[dc-rotate-creds] syncing KV -> AD for DSRM + domain Administrator + nexusadmin (lengths: $($dsrmPwd.Length), $($adminPwd.Length), $($nexusadminPwd.Length); MinPasswordLength=$minLen)"

      # Pre-flight: AD's Set-ADAccountPassword validates the new pwd against
      # the active Default Domain Password Policy. If KV holds a value that
      # violates the policy (e.g. legacy 11-char NexusDSRM!1 left over from
      # pre-0.D.5 + MinPasswordLength=14), the rotation would FAIL with
      # "password does not meet length requirements." Skip cleanly with a
      # WARN log instead -- operator's next move is to rotate KV to a
      # >=$minLen char value via `vault kv put nexus/foundation/...`, which
      # will change the creds_hash trigger on next apply and re-run.
      $shortest = [Math]::Min([Math]::Min($dsrmPwd.Length, $adminPwd.Length), $nexusadminPwd.Length)
      if ($shortest -lt $minLen) {
        Write-Host "[dc-rotate-creds] WARN: at least one KV value is shorter ($shortest chars) than MinPasswordLength=$minLen; skipping rotation."
        Write-Host "[dc-rotate-creds] NEXT STEP: rotate KV to >=$minLen-char pwds via scripts\rotate-foundation-creds.ps1 (or manual `vault kv put nexus/foundation/<path> password=...`)"
        Write-Host "[dc-rotate-creds] then re-run: pwsh -File scripts\foundation.ps1 apply"
        exit 0
      }
      Write-Host "[dc-rotate-creds] all three pwds satisfy MinPasswordLength=$minLen; proceeding with rotation"

      # Build a single PowerShell script to run on dc-nexus -- ntdsutil for
      # DSRM, Set-ADAccountPassword for the two domain users. Each step
      # emits a marker token so the build host can verify success.
      #
      # ntdsutil for DSRM: subcommands "set dsrm password" + "reset password
      # on server null" can be passed as argv, but the password itself goes
      # via STDIN -- ntdsutil opens an interactive "Please type password..."
      # prompt that ignores argv. We pipe the password (no confirm needed
      # for the "reset password on server null" mode) followed by the two
      # "q" lines to exit the nested prompts cleanly.
      # First-attempt bug (2026-05-02): tried to pass password as argv,
      # ntdsutil prompted, got empty input, failed with "Incorrect function"
      # then interpreted the password string as a command at the next
      # prompt level ("Invalid Syntax"). Diagnostic per
      # memory/feedback_diagnose_before_rewriting.md.
      #
      # Set-ADAccountPassword -Reset doesn't require knowing the OLD pwd
      # (admin override); -NewPassword takes a SecureString. ConvertTo-
      # SecureString from -AsPlainText is fine on Server 2025 PS 5.1.
      # DSRM rotation skipped: ntdsutil's password prompt fails under SSH /
      # redirected stdin with WIN32 Error Code 0x1. KV path stays as the
      # canonical "intended value"; manual sync via RDP+ntdsutil. See the
      # block comment at the top of this overlay for full diagnostic.
      $remote = @"
        try {
          # 1. Domain Administrator password reset
          Import-Module ActiveDirectory;
          `$secAdmin = ConvertTo-SecureString '$adminPwd' -AsPlainText -Force;
          Set-ADAccountPassword -Identity 'Administrator' -Reset -NewPassword `$secAdmin -ErrorAction Stop;
          Write-Output 'ADMINISTRATOR_ROTATED_OK';

          # 2. nexusadmin password reset
          `$secNexus = ConvertTo-SecureString '$nexusadminPwd' -AsPlainText -Force;
          Set-ADAccountPassword -Identity 'nexusadmin' -Reset -NewPassword `$secNexus -ErrorAction Stop;
          Write-Output 'NEXUSADMIN_ROTATED_OK';

          # 3. DSRM intentionally skipped (manual ops task; KV is the
          # intended-value store). Emit marker for completeness.
          Write-Output 'DSRM_SKIPPED_BY_DESIGN';
        } catch {
          Write-Output ('ROTATE_FAILED: ' + `$_.Exception.Message);
          exit 1;
        }
"@
      # Ship as file (scp + powershell -File) -- per memory
      # feedback_windows_ssh_automation.md rule #2, base64-encoded -EncodedCommand
      # fails when the encoded script exceeds cmd.exe's ~8 KB command-line
      # limit. Three sequential operations here (ntdsutil + 2x
      # Set-ADAccountPassword) put us right around the threshold; ship-as-
      # file sidesteps it entirely. The script also embeds plaintext pwds,
      # so we wipe the remote file on completion (success or failure).
      $tmpDir           = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "nexus-rotate-creds-$(Get-Random)")
      $localScriptPath  = Join-Path $tmpDir 'rotate-bootstrap-creds.ps1'
      $remoteScriptPath = 'C:/Windows/Temp/rotate-bootstrap-creds.ps1'
      # Append a self-cleanup line to the remote script so the plaintext
      # pwds aren't left on disk even if the SSH session disconnects.
      $remoteWithCleanup = $remote + "`nRemove-Item '$remoteScriptPath' -Force -ErrorAction SilentlyContinue`n"
      Set-Content -Path $localScriptPath -Value $remoteWithCleanup -Encoding UTF8

      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $localScriptPath "nexusadmin@$${ip}:$remoteScriptPath" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[dc-rotate-creds] scp of rotation script failed (rc=$LASTEXITCODE)"
      }

      $output = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteScriptPath" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

      # Best-effort remote cleanup in case the script's self-cleanup didn't run
      ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -Command \"Remove-Item '$remoteScriptPath' -Force -ErrorAction SilentlyContinue\"" 2>&1 | Out-Null

      Write-Host "[dc-rotate-creds] remote output:`n$($output.Trim())"

      if ($rc -ne 0 -or $output -notmatch 'ADMINISTRATOR_ROTATED_OK' -or $output -notmatch 'NEXUSADMIN_ROTATED_OK') {
        throw "[dc-rotate-creds] rotation failed (rc=$rc). At least one of Administrator/nexusadmin did not emit its OK marker."
      }

      Write-Host "[dc-rotate-creds] Administrator + nexusadmin synced KV -> AD"
      Write-Host "[dc-rotate-creds] DSRM rotation SKIPPED (manual ops task -- ntdsutil's pwd prompt fails over SSH; sync KV path nexus/foundation/dc-nexus/dsrm to live DC via RDP+ntdsutil. See docs/handbook.md s 1k.1.)"
    PWSH
  }
}
