/*
 * role-overlay-dc-vault-demo-rotated-account.tf -- Phase 0.D.3 step 3/4 (foundation)
 *
 * Create the AD service account `svc-demo-rotated` in OU=ServiceAccounts.
 * This is the target of Vault's secrets/ldap static rotate-role
 * (configured in envs/security/role-overlay-vault-ldap-rotate-role.tf).
 *
 * Lifecycle:
 *   - Initial password: random 24-char (set here, never persisted to disk).
 *   - On first apply of the security env's rotate-role, Vault rotates the
 *     password to a Vault-managed value. From then on, only Vault knows
 *     the current password; any consumer reads it via
 *     `vault read ldap/static-cred/svc-demo-rotated`.
 *   - Idempotency: if account already exists, no-op (don't reset pwd --
 *     Vault may already own it). If you ever need to manually reset,
 *     destroy + re-apply this overlay alone via `-target`.
 *
 * Selective ops: enable_vault_ad_integration AND
 *                enable_vault_ad_demo_rotated_account.
 */

resource "null_resource" "dc_vault_ad_demo_rotated_account" {
  count = var.enable_dc_promotion && var.enable_vault_ad_integration && var.enable_vault_ad_demo_rotated_account ? 1 : 0

  triggers = {
    dc_verify_id   = null_resource.dc_nexus_verify[0].id
    account_name   = var.vault_ad_demo_rotated_account_name
    demo_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_verify, null_resource.dc_ous]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.dc_nexus_ip}'
      $dnRoot      = '${local.ad_dn_root}'
      $accountName = '${var.vault_ad_demo_rotated_account_name}'

      # Generate one-time initial password locally; never persisted to disk.
      # Vault will replace it on first secrets/ldap static-role apply.
      function New-RandomPassword {
        param([int]$Length = 24)
        $sets = @(
          [char[]](65..90),
          [char[]](97..122),
          [char[]](48..57),
          [char[]]('!','#','$','%','&','*','+','-','.','=','?','@','_')
        )
        $required = $sets | ForEach-Object { $_ | Get-Random -Count 1 }
        $pool     = $sets | ForEach-Object { $_ } | Sort-Object -Unique
        $rest     = 1..($Length - $required.Count) | ForEach-Object { $pool | Get-Random }
        ((@($required) + @($rest)) | Sort-Object { Get-Random }) -join ''
      }
      $initialPwd = New-RandomPassword -Length 24

      Write-Host "[dc-vault-ad-demo] target account: $accountName"

      $remote = @"
        Import-Module ActiveDirectory;
        `$accountName = '$accountName';
        `$dnRoot      = '$dnRoot';
        `$pwdPlain    = '$initialPwd';
        `$securePwd   = ConvertTo-SecureString `$pwdPlain -AsPlainText -Force;
        `$existing    = `$null;
        try { `$existing = Get-ADUser -Identity `$accountName -ErrorAction Stop } catch { `$existing = `$null };
        if (`$existing) {
          Write-Output ('SKIPPED: ' + `$existing.DistinguishedName + ' already exists; Vault may own the password -- not resetting');
        } else {
          New-ADUser -Name `$accountName ``
            -SamAccountName `$accountName ``
            -UserPrincipalName ('${var.vault_ad_demo_rotated_account_name}@${local.ad_domain}') ``
            -Description 'Demo target for Vault secrets/ldap static rotate-role -- Vault owns the password from first rotation onward' ``
            -Path "OU=ServiceAccounts,`$dnRoot" ``
            -AccountPassword `$securePwd ``
            -PasswordNeverExpires `$true ``
            -CannotChangePassword `$false ``
            -Enabled `$true;
          Write-Output ('CREATED: CN=' + `$accountName + ',OU=ServiceAccounts,' + `$dnRoot + ' (initial random pwd; Vault will rotate)');
        }
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      $sshOut = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[dc-vault-ad-demo] script failed (rc=$LASTEXITCODE). Output:`n$sshOut"
      }
      Write-Host "[dc-vault-ad-demo] $($sshOut.Trim())"
    PWSH
  }
}
