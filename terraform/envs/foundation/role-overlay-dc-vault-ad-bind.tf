/*
 * role-overlay-dc-vault-ad-bind.tf -- Phase 0.D.3 step 1/4 (foundation side)
 *
 * Create the AD service account `svc-vault-ldap` in OU=ServiceAccounts.
 * This is the bind account Vault uses for both auth/ldap (humans login)
 * and secrets/ldap (AD password rotation engine).
 *
 * Lifecycle:
 *   1. Probe the DC via Get-ADUser to see if the account already exists.
 *   2. If missing OR if enable_vault_ad_bind_rotate_password=true:
 *      - Generate a strong random password on the build host (not the DC --
 *        avoids leaking pwd via DC syslog or eventlog).
 *      - Create-or-Set the AD account with that password
 *        (Enabled=true, PasswordNeverExpires=true so Vault's cached
 *        bindpass stays valid; member of built-in Users only -- no
 *        domain-admin priv).
 *      - Write {binddn,bindpass,...} into $HOME/.nexus/vault-ad-bind.json
 *        on the build host (mode 0600 equivalent).
 *   3. Otherwise (account exists + rotate=false): no-op. Preserves the
 *      bindpass that envs/security/ already cached on its last apply.
 *
 * Cross-env coupling:
 *   envs/security/role-overlay-vault-ldap-auth.tf reads the same file.
 *   Pattern mirrors vault-init.json from 0.D.1.
 *
 * Selective ops: enable_vault_ad_integration (master) AND
 *                enable_vault_ad_bind_account (per-step).
 *
 * Reachability invariant: pure AD object management on dc-nexus. No
 * Windows Firewall / sshd_config changes. Build-host SSH/RDP unaffected.
 */

resource "null_resource" "dc_vault_ad_bind" {
  count = var.enable_dc_promotion && var.enable_vault_ad_integration && var.enable_vault_ad_bind_account ? 1 : 0

  triggers = {
    dc_verify_id      = null_resource.dc_nexus_verify[0].id
    bind_account_name = var.vault_ad_bind_account_name
    bind_creds_file   = var.vault_ad_bind_creds_file
    rotate_password   = tostring(var.enable_vault_ad_bind_rotate_password)
    kv_ad_writeback   = tostring(var.enable_vault_kv_ad_writeback)
    bind_overlay_v    = "2" # v2 = Phase 0.D.4 KV writeback (writes generated pwd to nexus/foundation/ad/svc-vault-ldap when enable_vault_kv_ad_writeback=true). v1 = JSON-only.
  }

  depends_on = [null_resource.dc_nexus_verify, null_resource.dc_ous]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.dc_nexus_ip}'
      $dnRoot      = '${local.ad_dn_root}'
      $accountName = '${var.vault_ad_bind_account_name}'
      $rotate      = [bool]::Parse('${var.enable_vault_ad_bind_rotate_password}')
      $jsonPathRaw = '${var.vault_ad_bind_creds_file}'
      $jsonPath    = $ExecutionContext.InvokeCommand.ExpandString($jsonPathRaw.Replace('$HOME', $env:USERPROFILE))
      $bindDn      = "CN=$accountName,OU=ServiceAccounts,$dnRoot"

      Write-Host "[dc-vault-ad-bind] target account: $accountName  (DN: $bindDn)"

      # ─── Step A: probe DC for existing account ─────────────────────────
      $probeRemote = @"
        Import-Module ActiveDirectory;
        try {
          `$u = Get-ADUser -Identity '$accountName' -ErrorAction Stop;
          Write-Output ('EXISTS:' + `$u.DistinguishedName);
        } catch {
          Write-Output 'MISSING';
        }
"@
      $probeBytes = [System.Text.Encoding]::Unicode.GetBytes($probeRemote)
      $probeB64   = [Convert]::ToBase64String($probeBytes)
      $probeOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $probeB64" 2>&1 | Out-String
      $accountExists = $probeOut -match '\bEXISTS:'

      $jsonExists = Test-Path $jsonPath

      Write-Host "[dc-vault-ad-bind] AD account exists: $accountExists; JSON file exists: $jsonExists; rotate flag: $rotate"

      # ─── Step B: short-circuit if state is already canonical ───────────
      if ($accountExists -and $jsonExists -and -not $rotate) {
        Write-Host "[dc-vault-ad-bind] account + cached creds present, rotate=false; no-op"
        exit 0
      }

      # ─── Step C: generate a strong random password on the build host ───
      # 24 chars from a mixed alphabet; AD complexity requires at least one
      # of: uppercase, lowercase, digit, symbol -- our generator includes all.
      function New-RandomPassword {
        param([int]$Length = 24)
        $sets = @(
          [char[]](65..90),                                    # A-Z
          [char[]](97..122),                                   # a-z
          [char[]](48..57),                                    # 0-9
          [char[]]('!','#','$','%','&','*','+','-','.','=','?','@','_')
        )
        # one mandatory char from each set + remainder random across all
        $required = $sets | ForEach-Object { $_ | Get-Random -Count 1 }
        $pool     = $sets | ForEach-Object { $_ } | Sort-Object -Unique
        $rest     = 1..($Length - $required.Count) | ForEach-Object { $pool | Get-Random }
        # shuffle
        ((@($required) + @($rest)) | Sort-Object { Get-Random }) -join ''
      }
      $bindPwd = New-RandomPassword -Length 24

      # ─── Step D: create-or-set the AD account on the DC ────────────────
      # Single PS script does both create-if-missing + Set-ADAccountPassword
      # paths. The pwd ships in the encoded script -- safe over SSH because
      # the SSH channel is encrypted. EncodedCommand uses UTF-16-LE base64
      # (Windows PowerShell convention).
      $opRemote = @"
        Import-Module ActiveDirectory;
        `$accountName = '$accountName';
        `$dnRoot      = '$dnRoot';
        `$pwdPlain    = '$bindPwd';
        `$securePwd   = ConvertTo-SecureString `$pwdPlain -AsPlainText -Force;
        `$existing    = `$null;
        try { `$existing = Get-ADUser -Identity `$accountName -ErrorAction Stop } catch { `$existing = `$null };
        if (-not `$existing) {
          New-ADUser -Name `$accountName ``
            -SamAccountName `$accountName ``
            -UserPrincipalName ('${var.vault_ad_bind_account_name}@${local.ad_domain}') ``
            -Description 'Vault LDAP bind account (auth/ldap + secrets/ldap)' ``
            -Path "OU=ServiceAccounts,`$dnRoot" ``
            -AccountPassword `$securePwd ``
            -PasswordNeverExpires `$true ``
            -CannotChangePassword `$false ``
            -Enabled `$true;
          Write-Output ('CREATED:CN=' + `$accountName + ',OU=ServiceAccounts,' + `$dnRoot);
        } else {
          Set-ADAccountPassword -Identity `$accountName -Reset -NewPassword `$securePwd;
          Set-ADUser -Identity `$accountName -PasswordNeverExpires `$true -Enabled `$true;
          Write-Output ('PWDSET:' + `$existing.DistinguishedName);
        }
"@
      $opBytes = [System.Text.Encoding]::Unicode.GetBytes($opRemote)
      $opB64   = [Convert]::ToBase64String($opBytes)
      $opOut = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $opB64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or -not ($opOut -match '\b(CREATED|PWDSET):')) {
        throw "[dc-vault-ad-bind] AD account create/set-password failed. Output:`n$opOut"
      }
      Write-Host "[dc-vault-ad-bind] $($opOut.Trim())"

      # ─── Step E: persist bind cred to JSON file (atomic merge) ─────────
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
      $h.binddn        = $bindDn
      $h.bindpass      = $bindPwd
      $h.bind_username = $accountName
      $h.ldap_url      = 'ldap://${local.dc_nexus_ip}:389'
      $h.rotated_at    = (Get-Date).ToUniversalTime().ToString('o')

      ($h | ConvertTo-Json -Depth 4) | Set-Content -Path $jsonPath -Encoding UTF8

      # NTFS owner-only ACL (mode 0600 equivalent on Win)
      icacls $jsonPath /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null

      Write-Host "[dc-vault-ad-bind] persisted bind cred to $${jsonPath} (mode 0600 equivalent via icacls)"
      Write-Host "[dc-vault-ad-bind] CRITICAL: vault-ad-bind.json holds the bindpass; back it up + protect it"

      # ─── Phase 0.D.4: also write to Vault KV (canonical store) ─────────
      # Best-effort; if Vault isn't up yet (security env not applied,
      # vault-init.json missing, vault-1 unreachable), log WARN and continue.
      # The seed overlay in security env will migrate the JSON contents on
      # its next apply.
      if ([bool]::Parse('${var.enable_vault_kv_ad_writeback}')) {
        $vaultInitFile = Join-Path $env:USERPROFILE '.nexus\vault-init.json'
        if (Test-Path $vaultInitFile) {
          $rootToken = $null
          try { $rootToken = (Get-Content $vaultInitFile -Raw | ConvertFrom-Json).root_token } catch { }
          if ($rootToken) {
            $kvBodyJson = (@{ binddn = $bindDn; username = $accountName; password = $bindPwd } | ConvertTo-Json -Compress)
            $kvBodyB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($kvBodyJson))
            $kvBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://192.168.70.121:8200
TMP=`$(mktemp); trap 'rm -f "`$TMP"' EXIT
echo '$kvBodyB64' | base64 -d > "`$TMP"
vault kv put 'nexus/foundation/ad/$accountName' @"`$TMP" >/dev/null
echo "[dc-vault-ad-bind] KV writeback to nexus/foundation/ad/$accountName -- OK"
"@
            $kvBashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($kvBash))
            $kvOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@192.168.70.121 "echo '$kvBashB64' | base64 -d | bash" 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
              Write-Host $kvOut.Trim()
            } else {
              Write-Host "[dc-vault-ad-bind] WARN: KV writeback failed (rc=$LASTEXITCODE); JSON file remains canonical. Output:`n$($kvOut.Trim())"
            }
          } else {
            Write-Host "[dc-vault-ad-bind] WARN: KV writeback skipped (vault-init.json unparseable / no root_token)"
          }
        } else {
          Write-Host "[dc-vault-ad-bind] WARN: KV writeback skipped -- $vaultInitFile not present (security env not yet applied; seed overlay will migrate from JSON)"
        }
      }
    PWSH
  }
}
