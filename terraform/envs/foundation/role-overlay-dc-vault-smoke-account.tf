/*
 * role-overlay-dc-vault-smoke-account.tf -- Phase 0.D.3 step 4/4 (foundation)
 *
 * Create the AD service account `svc-vault-smoke` in OU=ServiceAccounts.
 * This is the credential the 0.D.3 smoke gate uses for its end-to-end
 * `vault login -method=ldap` probe. Plaintext password persists in
 * vault-ad-bind.json on the build host (alongside the bind cred).
 *
 * Why a dedicated smoke account (not nexusadmin):
 *   - Decouples the smoke gate from any future rotation of nexusadmin.
 *   - Avoids polluting nexusadmin's session attribution in Vault audit
 *     logs (every smoke run would otherwise look like a real admin login).
 *   - Lets the smoke account's policy mapping be tightly scoped (it goes
 *     into `nexus-vault-readers` -> `nexus-reader` policy -- read-only).
 *
 * Lifecycle (mirrors svc-vault-ldap):
 *   - On first apply: account does not exist -> generate random pwd, create
 *     account, write smoke_username + smoke_password into vault-ad-bind.json
 *     (atomic merge with the bind cred written by step 1/4).
 *   - Subsequent applies: account exists + JSON has smoke_password -> no-op.
 *   - Recovery (account exists but JSON lost smoke_password): regenerate
 *     pwd, set on AD, persist in JSON.
 *   - The smoke account is also enrolled in the `nexus-vault-readers`
 *     group so the LDAP login probe maps to the nexus-reader Vault policy.
 *
 * Selective ops: enable_vault_ad_integration AND enable_vault_ad_smoke_account.
 */

resource "null_resource" "dc_vault_ad_smoke_account" {
  count = var.enable_dc_promotion && var.enable_vault_ad_integration && var.enable_vault_ad_smoke_account ? 1 : 0

  triggers = {
    dc_verify_id    = null_resource.dc_nexus_verify[0].id
    account_name    = var.vault_ad_smoke_account_name
    group_readers   = var.vault_ad_group_readers
    bind_creds_file = var.vault_ad_bind_creds_file
    smoke_overlay_v = "1"
  }

  depends_on = [
    null_resource.dc_nexus_verify,
    null_resource.dc_ous,
    null_resource.dc_vault_ad_groups, # readers group must exist before we enroll
    null_resource.dc_vault_ad_bind,   # bind overlay seeds the JSON we merge into
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.dc_nexus_ip}'
      $dnRoot      = '${local.ad_dn_root}'
      $accountName = '${var.vault_ad_smoke_account_name}'
      $groupReaders = '${var.vault_ad_group_readers}'
      $jsonPathRaw = '${var.vault_ad_bind_creds_file}'
      $jsonPath    = $ExecutionContext.InvokeCommand.ExpandString($jsonPathRaw.Replace('$HOME', $env:USERPROFILE))

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

      # ─── Decide if smoke pwd needs (re)generation ──────────────────────
      $cachedPwd = $null
      if (Test-Path $jsonPath) {
        try {
          $j = Get-Content $jsonPath -Raw | ConvertFrom-Json
          if ($j.smoke_password) { $cachedPwd = $j.smoke_password }
        } catch { }
      }

      # Probe DC for account
      $probeRemote = @"
        Import-Module ActiveDirectory;
        try { `$u = Get-ADUser -Identity '$accountName' -ErrorAction Stop; Write-Output ('EXISTS:' + `$u.DistinguishedName) } catch { Write-Output 'MISSING' }
"@
      $probeBytes = [System.Text.Encoding]::Unicode.GetBytes($probeRemote)
      $probeB64   = [Convert]::ToBase64String($probeBytes)
      $probeOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $probeB64" 2>&1 | Out-String
      $accountExists = $probeOut -match '\bEXISTS:'

      Write-Host "[dc-vault-ad-smoke] account exists: $accountExists; cached smoke_password present: $([bool]$cachedPwd)"

      if ($accountExists -and $cachedPwd) {
        Write-Host "[dc-vault-ad-smoke] both account + cached pwd present; ensuring group membership only"
        $smokePwd = $cachedPwd
        $needsCreateOrSet = $false
      } else {
        $smokePwd = New-RandomPassword -Length 24
        $needsCreateOrSet = $true
      }

      # ─── Create-or-set + group enrollment in one remote script ─────────
      $opRemote = @"
        Import-Module ActiveDirectory;
        `$accountName  = '$accountName';
        `$dnRoot       = '$dnRoot';
        `$pwdPlain     = '$smokePwd';
        `$securePwd    = ConvertTo-SecureString `$pwdPlain -AsPlainText -Force;
        `$groupReaders = '$groupReaders';
        `$needsCreateOrSet = [bool]::Parse('$needsCreateOrSet');

        `$existing = `$null;
        try { `$existing = Get-ADUser -Identity `$accountName -ErrorAction Stop } catch { `$existing = `$null };

        if (-not `$existing) {
          New-ADUser -Name `$accountName ``
            -SamAccountName `$accountName ``
            -UserPrincipalName ('${var.vault_ad_smoke_account_name}@${local.ad_domain}') ``
            -Description 'Test account for 0.D.3 smoke gate vault login -method=ldap probe (read-only)' ``
            -Path "OU=ServiceAccounts,`$dnRoot" ``
            -AccountPassword `$securePwd ``
            -PasswordNeverExpires `$true ``
            -CannotChangePassword `$false ``
            -Enabled `$true;
          Write-Output ('CREATED: CN=' + `$accountName + ',OU=ServiceAccounts,' + `$dnRoot);
        } elseif (`$needsCreateOrSet) {
          Set-ADAccountPassword -Identity `$accountName -Reset -NewPassword `$securePwd;
          Set-ADUser -Identity `$accountName -PasswordNeverExpires `$true -Enabled `$true;
          Write-Output ('PWDSET: ' + `$existing.DistinguishedName);
        } else {
          Write-Output ('PRESENT: ' + `$existing.DistinguishedName);
        }

        # Idempotent group enrollment
        `$alreadyMember = `$false;
        try {
          `$members = Get-ADGroupMember -Identity `$groupReaders -ErrorAction Stop;
          `$alreadyMember = (`$members | Where-Object { `$_.SamAccountName -eq `$accountName }) -ne `$null;
        } catch { };
        if (`$alreadyMember) {
          Write-Output ('MEMBER_PRESENT: ' + `$accountName + ' already in ' + `$groupReaders);
        } else {
          Add-ADGroupMember -Identity `$groupReaders -Members `$accountName;
          Write-Output ('MEMBER_ADDED: ' + `$accountName + ' -> ' + `$groupReaders);
        }
"@
      $opBytes = [System.Text.Encoding]::Unicode.GetBytes($opRemote)
      $opB64   = [Convert]::ToBase64String($opBytes)
      $opOut = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $opB64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or -not ($opOut -match '\b(CREATED|PWDSET|PRESENT):')) {
        throw "[dc-vault-ad-smoke] script failed. Output:`n$opOut"
      }
      Write-Host "[dc-vault-ad-smoke] $($opOut.Trim())"

      # ─── Persist smoke cred to JSON file (atomic merge) ────────────────
      if ($needsCreateOrSet) {
        $jsonDir = Split-Path -Parent $jsonPath
        New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null
        $existingObj = $null
        if (Test-Path $jsonPath) {
          try { $existingObj = Get-Content $jsonPath -Raw | ConvertFrom-Json } catch { }
        }
        $h = @{}
        if ($existingObj) {
          $existingObj.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
        }
        $h.smoke_username = $accountName
        $h.smoke_password = $smokePwd
        $h.smoke_set_at   = (Get-Date).ToUniversalTime().ToString('o')
        ($h | ConvertTo-Json -Depth 4) | Set-Content -Path $jsonPath -Encoding UTF8
        icacls $jsonPath /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null
        Write-Host "[dc-vault-ad-smoke] persisted smoke_username + smoke_password to $${jsonPath}"
      } else {
        Write-Host "[dc-vault-ad-smoke] cached smoke_password preserved; no JSON rewrite"
      }
    PWSH
  }
}
