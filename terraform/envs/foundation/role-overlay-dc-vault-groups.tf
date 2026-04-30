/*
 * role-overlay-dc-vault-groups.tf -- Phase 0.D.3 step 2/4 (foundation side)
 *
 * Create three AD security groups in OU=Groups for Vault role mapping:
 *
 *   nexus-vault-admins    -> Vault policy `nexus-admin`    (full sudo)
 *   nexus-vault-operators -> Vault policy `nexus-operator` (R/W on nexus/* + cert issuance via pki_int/issue/*; no sudo)
 *   nexus-vault-readers   -> Vault policy `nexus-reader`   (read-only on nexus/*)
 *
 * Add `nexusadmin` to nexus-vault-admins so the operator can `vault login
 * -method=ldap -username=nexusadmin -password=<AD pwd>` after envs/security
 * applies the LDAP auth method.
 *
 * Group->policy mapping itself happens on the Vault side
 * (envs/security/role-overlay-vault-ldap-auth.tf). This overlay only
 * creates the AD objects; Vault references them by group name (cn).
 *
 * Idempotency: each group probed via Get-ADGroup before New-ADGroup; member
 * add probed via (Get-ADGroupMember | Where ...) before Add-ADGroupMember.
 *
 * Selective ops: enable_vault_ad_integration AND enable_vault_ad_groups.
 */

resource "null_resource" "dc_vault_ad_groups" {
  count = var.enable_dc_promotion && var.enable_vault_ad_integration && var.enable_vault_ad_groups ? 1 : 0

  triggers = {
    dc_verify_id     = null_resource.dc_nexus_verify[0].id
    group_admins     = var.vault_ad_group_admins
    group_operators  = var.vault_ad_group_operators
    group_readers    = var.vault_ad_group_readers
    groups_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_verify, null_resource.dc_ous]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip            = '${local.dc_nexus_ip}'
      $dnRoot        = '${local.ad_dn_root}'
      $groupAdmins   = '${var.vault_ad_group_admins}'
      $groupOps      = '${var.vault_ad_group_operators}'
      $groupReaders  = '${var.vault_ad_group_readers}'

      Write-Host "[dc-vault-ad-groups] dispatching group create + nexusadmin enrollment on $ip"

      $remote = @"
        Import-Module ActiveDirectory;
        `$groups = @(
          @{ Name = '$groupAdmins';   Description = 'Vault auth/ldap -> nexus-admin policy (full sudo on Vault)' },
          @{ Name = '$groupOps';      Description = 'Vault auth/ldap -> nexus-operator policy (R/W on nexus/*, cert issuance via pki_int)' },
          @{ Name = '$groupReaders';  Description = 'Vault auth/ldap -> nexus-reader policy (read-only on nexus/*)' }
        );
        `$created = @(); `$skipped = @();
        foreach (`$g in `$groups) {
          `$existing = `$null;
          try { `$existing = Get-ADGroup -Identity `$g.Name -ErrorAction Stop } catch { `$existing = `$null };
          if (`$existing) {
            `$skipped += `$g.Name;
          } else {
            New-ADGroup ``
              -Name `$g.Name ``
              -SamAccountName `$g.Name ``
              -GroupScope Global ``
              -GroupCategory Security ``
              -Path "OU=Groups,$dnRoot" ``
              -Description `$g.Description;
            `$created += `$g.Name;
          }
        };
        Write-Output ('GROUPS_CREATED:' + (`$created -join ','));
        Write-Output ('GROUPS_SKIPPED:' + (`$skipped -join ','));

        # Enroll nexusadmin in admins group (idempotent)
        `$adminUserObj = `$null;
        try { `$adminUserObj = Get-ADUser -Identity 'nexusadmin' -ErrorAction Stop } catch { };
        if (-not `$adminUserObj) {
          Write-Output 'MEMBER_SKIP: nexusadmin user not found in AD (post-promotion migration not done?)';
        } else {
          `$alreadyMember = `$false;
          try {
            `$members = Get-ADGroupMember -Identity '$groupAdmins' -ErrorAction Stop;
            `$alreadyMember = (`$members | Where-Object { `$_.SamAccountName -eq 'nexusadmin' }) -ne `$null;
          } catch { };
          if (`$alreadyMember) {
            Write-Output 'MEMBER_PRESENT: nexusadmin already in $groupAdmins';
          } else {
            Add-ADGroupMember -Identity '$groupAdmins' -Members 'nexusadmin';
            Write-Output 'MEMBER_ADDED: nexusadmin -> $groupAdmins';
          }
        }
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      $sshOut = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[dc-vault-ad-groups] script failed (rc=$LASTEXITCODE). Output:`n$sshOut"
      }
      Write-Host "[dc-vault-ad-groups] $($sshOut.Trim())"
    PWSH
  }
}
