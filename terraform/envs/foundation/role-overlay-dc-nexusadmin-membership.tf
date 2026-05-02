/*
 * role-overlay-dc-nexusadmin-membership.tf -- Phase 0.D.5 prerequisite
 *
 * Idempotently asserts nexusadmin's membership in Domain Admins +
 * Enterprise Admins (from var.dc_nexusadmin_required_groups). Required
 * by Add-KdsRootKey (5.3 GMSA) and any future overlay needing explicit
 * Enterprise/Domain Admins token rather than Builtin\Administrators
 * inheritance.
 *
 * Why we can't just have nexusadmin do it: nexusadmin currently isn't
 * in Domain Admins (the dc_nexus_promote v4 step's chained one-liner
 * Add-ADGroupMember silently failed at original promotion time).
 * Builtin\Administrators on the DC has the rights to call this cmdlet,
 * but the AD module's ADWS connection uses the SSH session's identity
 * (nexusadmin) for AuthZ -- which doesn't have Domain Admin and gets
 * "Insufficient access rights" rejection.
 *
 * Solution: read the domain Administrator's password from Vault KV at
 * nexus/foundation/dc-nexus/local-administrator (post-5.1, this is a
 * 24-char Vault-generated value matching what's live on the DC after
 * dc_rotate_bootstrap_creds synced). Build a PSCredential and pass to
 * Add-ADGroupMember -Credential so the call goes as Administrator.
 *
 * Idempotency: probe Get-ADUser nexusadmin -Properties MemberOf for each
 * required group; add only if missing. Order in the list matters because
 * Enterprise Admins itself can only be modified by current Enterprise
 * Admins or Schema Admins -- so add Domain Admins first (Administrator
 * is in DA + EA, can do both).
 *
 * Selective ops: enable_dc_promotion + enable_vault_kv_creds (need KV
 * for the Administrator credential) + enable_dc_nexusadmin_membership.
 *
 * Reachability invariant: pure AD object management. Build-host
 * SSH/RDP unaffected.
 *
 * Security note: the Administrator password is embedded in the script
 * file briefly during apply (file-ship pattern) and wiped on remote
 * cleanup. Same trade-off as dc_rotate_bootstrap_creds.
 */

resource "null_resource" "dc_nexusadmin_membership" {
  count = var.enable_dc_promotion && var.enable_vault_kv_creds && var.enable_dc_nexusadmin_membership ? 1 : 0

  triggers = {
    dc_verify_id  = null_resource.dc_nexus_verify[0].id
    target_groups = join(",", var.dc_nexusadmin_required_groups)
    # creds_hash uses Administrator pwd to detect rotations -- if the
    # Administrator pwd in KV changes, the membership overlay re-runs
    # with the new pwd. Idempotent (already-member groups become no-op).
    admin_pwd_hash       = sha256(local.foundation_creds.local_administrator)
    membership_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip        = '${local.dc_nexus_ip}'
      $adminPwd  = '${local.foundation_creds.local_administrator}'
      $groupsCsv = '${join(",", var.dc_nexusadmin_required_groups)}'

      Write-Host "[dc-nexusadmin-membership] asserting nexusadmin membership in: $groupsCsv"

      # Build the remote PowerShell script. Uses Administrator credential
      # (from KV) to authenticate AD cmdlet calls. Idempotent: probes
      # current membership, adds only if missing. Group list shipped as
      # a comma-joined string + Split on the remote side (avoids the
      # HCL/PS array-interpolation impedance mismatch).
      $remote = @"
        try {
          Import-Module ActiveDirectory;
          `$secAdmin = ConvertTo-SecureString '$adminPwd' -AsPlainText -Force;
          `$cred = New-Object System.Management.Automation.PSCredential('Administrator', `$secAdmin);

          # Test the credential first by reading something. If this fails,
          # the KV pwd doesn't match live AD -- bail with a clear message.
          try {
            `$probe = Get-ADUser -Identity 'Administrator' -Credential `$cred -ErrorAction Stop;
          } catch {
            Write-Output ('CRED_FAILED: Administrator credential from Vault KV does not authenticate against AD: ' + `$_.Exception.Message);
            exit 1;
          }

          `$groupList = '$groupsCsv'.Split(',');
          `$results = @();
          foreach (`$grp in `$groupList) {
            `$members = Get-ADGroupMember -Identity `$grp -Credential `$cred -ErrorAction SilentlyContinue;
            `$alreadyMember = (`$members | Where-Object { `$_.SamAccountName -eq 'nexusadmin' }) -ne `$null;
            if (`$alreadyMember) {
              `$results += "ALREADY_MEMBER: nexusadmin in `$grp";
            } else {
              Add-ADGroupMember -Identity `$grp -Members 'nexusadmin' -Credential `$cred -ErrorAction Stop;
              `$results += "ADDED_MEMBER: nexusadmin -> `$grp";
            }
          }
          `$results | ForEach-Object { Write-Output `$_ };
          Write-Output 'MEMBERSHIP_OK';
        } catch {
          Write-Output ('MEMBERSHIP_FAILED: ' + `$_.Exception.Message);
          exit 1;
        }
"@

      # Ship as file (script + admin pwd embedded; self-cleanup on remote)
      $tmpDir          = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "nexus-membership-$(Get-Random)")
      $localScriptPath = Join-Path $tmpDir 'assert-nexusadmin-membership.ps1'
      $remoteScriptPath = 'C:/Windows/Temp/assert-nexusadmin-membership.ps1'
      $remoteWithCleanup = $remote + "`nRemove-Item '$remoteScriptPath' -Force -ErrorAction SilentlyContinue`n"
      Set-Content -Path $localScriptPath -Value $remoteWithCleanup -Encoding UTF8

      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $localScriptPath "nexusadmin@$${ip}:$remoteScriptPath" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[dc-nexusadmin-membership] scp of script failed (rc=$LASTEXITCODE)"
      }

      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteScriptPath" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

      # Best-effort remote cleanup in case the script's self-cleanup didn't run
      ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -Command \"Remove-Item '$remoteScriptPath' -Force -ErrorAction SilentlyContinue\"" 2>&1 | Out-Null

      Write-Host "[dc-nexusadmin-membership] remote output:`n$($output.Trim())"

      if ($rc -ne 0 -or $output -notmatch 'MEMBERSHIP_OK') {
        throw "[dc-nexusadmin-membership] failed (rc=$rc). Either the Administrator KV cred doesn't match live AD (rotate via scripts\rotate-foundation-creds.ps1 + apply foundation), or the cmdlet rejected the operation."
      }

      Write-Host "[dc-nexusadmin-membership] OK -- nexusadmin is in: $groupsCsv"
    PWSH
  }
}
