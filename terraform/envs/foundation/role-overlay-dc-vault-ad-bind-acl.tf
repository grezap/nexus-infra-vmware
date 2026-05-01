/*
 * role-overlay-dc-vault-ad-bind-acl.tf -- Phase 0.D.3 (foundation side, ACL delegation)
 *
 * Delegates to the Vault LDAP bind account (svc-vault-ldap) the AD
 * extended rights it needs to rotate passwords on accounts under
 * OU=ServiceAccounts. Without this delegation, Vault's
 * `secrets/ldap` engine binds successfully but every static-role
 * rotation fails with:
 *
 *   LDAP Result Code 50 "Insufficient Access Rights":
 *   00000005: SecErr: DSID-031A1248, problem 4003 (INSUFF_ACCESS_RIGHTS), data 0
 *
 * which is AD's "the bound user has no Reset Password right on the
 * target object" response.
 *
 * Required ACEs (per HashiCorp KB "Active Directory Secrets Engine Setup"
 * https://support.hashicorp.com/hc/en-us/articles/4404332050579 -- this
 * is the canonical doc; the public developer.hashicorp.com page only
 * says "administrator level LDAP bind account" without the per-ACE list):
 *
 *   1. Reset Password    -- extended right (Control Access),
 *                           GUID 00299570-246d-11d0-a768-00aa006e0529
 *                           (User-Force-Change-Password). Mandatory.
 *                           Vault writes unicodePwd via this right.
 *   2. Change Password   -- extended right,
 *                           GUID ab721a53-1e2f-11d0-9819-00aa0040529b
 *                           (User-Change-Password). HashiCorp lists this
 *                           in their KB; we grant for completeness.
 *   3. Read userAccountControl  -- read property on the userAccountControl
 *                                  attribute (Vault inspects flags before
 *                                  rotating to avoid touching disabled
 *                                  accounts).
 *   4. Write userAccountControl -- write property; covers the case where
 *                                  Vault clears UF_PASSWORD_NOTREQD or
 *                                  similar bits during rotation.
 *
 * All four are scoped to inherit onto descendant user objects only
 * (dsacls /I:S /G "<trustee>:...;user"), so future accounts added to
 * OU=ServiceAccounts inherit automatically without per-account fiddling.
 *
 * NOT in scope:
 *   - pwdLastSet write (Vault's `schema=ad` rotation does not write it)
 *   - lockoutTime write (not part of the static-role rotation path)
 *   - Account Operators group membership (HashiCorp's coarse alternative;
 *     rejected here -- it grants password reset on most non-protected
 *     accounts domain-wide, much wider blast radius than this lab needs)
 *
 * Tool: dsacls.exe (built into Server 2025 with the AD DS role) handles
 * the extended-right grants by string name, much cleaner than constructing
 * ActiveDirectoryAccessRule objects manually. We invoke it via SSH to
 * the DC. Idempotency: probe the DACL first via Get-Acl + filter for our
 * trustee's existing ACEs, skip the grant if all four expected ones
 * already exist.
 *
 * Depends on:
 *   - dc_ous (OU=ServiceAccounts must exist)
 *   - dc_vault_ad_bind (svc-vault-ldap must exist; otherwise dsacls
 *     can't resolve the trustee SID and silently skips its work)
 *
 * Selective ops: enable_vault_ad_integration (master) AND
 *                enable_vault_ad_bind_acl_delegation (per-step, default true).
 *
 * Reachability invariant: pure DACL change on AD; no service restart,
 * no firewall change, no listener change. Build-host SSH/RDP unaffected.
 */

resource "null_resource" "dc_vault_ad_bind_acl" {
  count = var.enable_dc_promotion && var.enable_vault_ad_integration && var.enable_vault_ad_bind_account && var.enable_vault_ad_bind_acl_delegation ? 1 : 0

  triggers = {
    bind_account_id = null_resource.dc_vault_ad_bind[0].id
    ous_id          = null_resource.dc_ous[0].id
    bind_account    = var.vault_ad_bind_account_name
    acl_overlay_v   = "1"
  }

  depends_on = [null_resource.dc_vault_ad_bind, null_resource.dc_ous]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.dc_nexus_ip}'
      $dnRoot      = '${local.ad_dn_root}'
      $accountName = '${var.vault_ad_bind_account_name}'
      $ouDn        = "OU=ServiceAccounts,$dnRoot"

      Write-Host "[dc-vault-ad-bind-acl] delegating AD password-reset rights for $accountName on $ouDn"

      # ─── Idempotency probe: do all four expected ACEs already exist? ──
      # Filter Get-Acl on the OU for ACEs whose IdentityReference is our
      # trustee, count distinct ObjectType GUIDs we care about.
      $probeRemote = @"
        Import-Module ActiveDirectory;
        `$acl = Get-Acl ('AD:' + '$ouDn');
        `$me  = `$acl.Access | Where-Object { `$_.IdentityReference -match '$accountName' };
        `$resetGuid    = '00299570-246d-11d0-a768-00aa006e0529';
        `$changeGuid   = 'ab721a53-1e2f-11d0-9819-00aa0040529b';
        `$uacGuid      = 'bf967a68-0de6-11d0-a285-00aa003049e2';
        `$hasReset     = (`$me | Where-Object { `$_.ObjectType -eq `$resetGuid  -and `$_.AccessControlType -eq 'Allow' }) -ne `$null;
        `$hasChange    = (`$me | Where-Object { `$_.ObjectType -eq `$changeGuid -and `$_.AccessControlType -eq 'Allow' }) -ne `$null;
        `$hasUacRead   = (`$me | Where-Object { `$_.ObjectType -eq `$uacGuid    -and `$_.ActiveDirectoryRights -match 'ReadProperty'  -and `$_.AccessControlType -eq 'Allow' }) -ne `$null;
        `$hasUacWrite  = (`$me | Where-Object { `$_.ObjectType -eq `$uacGuid    -and `$_.ActiveDirectoryRights -match 'WriteProperty' -and `$_.AccessControlType -eq 'Allow' }) -ne `$null;
        if (`$hasReset -and `$hasChange -and `$hasUacRead -and `$hasUacWrite) {
          Write-Output 'ACL_OK: all four ACEs present'
        } else {
          Write-Output ('ACL_INCOMPLETE: reset=' + `$hasReset + ' change=' + `$hasChange + ' uacRead=' + `$hasUacRead + ' uacWrite=' + `$hasUacWrite)
        }
"@
      $probeBytes = [System.Text.Encoding]::Unicode.GetBytes($probeRemote)
      $probeB64   = [Convert]::ToBase64String($probeBytes)
      $probeOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $probeB64" 2>&1 | Out-String

      if ($probeOut -match '\bACL_OK:') {
        Write-Host "[dc-vault-ad-bind-acl] all four ACEs already delegated; no-op"
        Write-Host "  $($probeOut.Trim())"
        exit 0
      }
      Write-Host "[dc-vault-ad-bind-acl] ACEs incomplete or missing -- delegating now"
      Write-Host "  probe: $($probeOut.Trim())"

      # ─── Delegate via dsacls.exe ──────────────────────────────────────
      # /R <trustee>  removes any existing explicit ACEs for the trustee
      #               (does not touch inherited ACEs from parents). This
      #               is the clean-slate before /G; without it, repeated
      #               applies stack identical ACEs.
      # /I:S          inherit to child objects only (not the OU itself)
      # /G            grant ACE
      # CA;<right>    Control Access (extended right) by display name
      # RPWP          Read Property + Write Property
      # ;user         scope inheritance to user-class objects only
      $opRemote = @"
        `$ouDn    = '$ouDn';
        `$trustee = 'NEXUS\$accountName';

        Write-Output ('--- dsacls /R for ' + `$trustee + ' on ' + `$ouDn);
        & dsacls.exe `$ouDn /R `$trustee | Out-Host;

        Write-Output '--- dsacls /G CA;Reset Password;user';
        & dsacls.exe `$ouDn /I:S /G ('{0}:CA;Reset Password;user'  -f `$trustee) | Out-Host;

        Write-Output '--- dsacls /G CA;Change Password;user';
        & dsacls.exe `$ouDn /I:S /G ('{0}:CA;Change Password;user' -f `$trustee) | Out-Host;

        Write-Output '--- dsacls /G RPWP;userAccountControl;user';
        & dsacls.exe `$ouDn /I:S /G ('{0}:RPWP;userAccountControl;user' -f `$trustee) | Out-Host;

        Write-Output '--- post-grant ACEs for trustee (verify) ---';
        Import-Module ActiveDirectory;
        `$acl = Get-Acl ('AD:' + `$ouDn);
        `$mine = `$acl.Access | Where-Object { `$_.IdentityReference -match '$accountName' } |
          Select-Object IdentityReference, ActiveDirectoryRights, ObjectType, InheritedObjectType, AccessControlType;
        `$mine | Format-Table | Out-String | Write-Output;

        if ((`$mine | Measure-Object).Count -lt 3) {
          Write-Output 'GRANT_INCOMPLETE: fewer ACEs visible after dsacls than expected';
          exit 1;
        }
        Write-Output 'GRANT_OK';
"@
      $opBytes = [System.Text.Encoding]::Unicode.GetBytes($opRemote)
      $opB64   = [Convert]::ToBase64String($opBytes)
      $opOut = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $opB64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or -not ($opOut -match '\bGRANT_OK\b')) {
        throw "[dc-vault-ad-bind-acl] dsacls grant failed. Output:`n$opOut"
      }
      Write-Host $opOut.Trim()
      Write-Host "[dc-vault-ad-bind-acl] $accountName now holds Reset/Change Password + RPWP userAccountControl on user objects under $ouDn"
    PWSH
  }
}
