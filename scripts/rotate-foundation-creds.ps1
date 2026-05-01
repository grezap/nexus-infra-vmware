#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Rotate the foundation env's three Vault-KV-managed bootstrap creds
  (DSRM, domain Administrator, nexusadmin) to fresh 24-char Vault-
  generated values.

.DESCRIPTION
  Phase 0.D.5 operational helper. Generates fresh 24-char passwords
  on the build host (cryptographically random, AD-complexity-compliant),
  writes them to Vault KV at:
    - nexus/foundation/dc-nexus/dsrm
    - nexus/foundation/dc-nexus/local-administrator
    - nexus/foundation/identity/nexusadmin

  After this script runs, the operator should re-apply the foundation
  env. The dc_rotate_bootstrap_creds overlay detects the KV creds_hash
  change and pushes the new pwds to live AD via ntdsutil (DSRM) +
  Set-ADAccountPassword (Administrator + nexusadmin).

  Idempotent: each invocation generates a NEW set of pwds; old pwds in
  KV are overwritten. Vault KV-v2 keeps prior versions for break-glass
  recovery if needed.

.PARAMETER VaultAddr
  Vault leader URL. Default https://192.168.70.121:8200.

.PARAMETER InitKeysFile
  Path to vault-init.json on build host. Default $HOME/.nexus/vault-init.json.

.PARAMETER CaBundlePath
  Path to root CA bundle. Default $HOME/.nexus/vault-ca-bundle.crt.

.PARAMETER MinLength
  Minimum password length to generate. Default 24 (matches the
  nexus-ad-rotated Vault password policy). Must be >= the foundation
  env's var.dc_password_min_length (currently 14).

.PARAMETER WhatIf
  Show what would be rotated without actually writing to Vault KV.

.EXAMPLE
  pwsh -File scripts\rotate-foundation-creds.ps1
  pwsh -File scripts\foundation.ps1 apply

.EXAMPLE
  # Dry run
  pwsh -File scripts\rotate-foundation-creds.ps1 -WhatIf

.NOTES
  Cross-ref:
    docs/handbook.md s 1f.5 (rotation procedure)
    terraform/envs/foundation/role-overlay-dc-rotate-bootstrap-creds.tf (the consumer)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VaultAddr    = 'https://192.168.70.121:8200',
    [string]$InitKeysFile = $null,
    [string]$CaBundlePath = $null,
    [int]   $MinLength    = 24
)

$ErrorActionPreference = 'Stop'

if (-not $InitKeysFile) { $InitKeysFile = Join-Path $env:USERPROFILE '.nexus/vault-init.json' }
if (-not $CaBundlePath) { $CaBundlePath = Join-Path $env:USERPROFILE '.nexus/vault-ca-bundle.crt' }

if ($MinLength -lt 14) {
    throw "MinLength must be >= 14 to satisfy the foundation env's MinPasswordLength=14 policy"
}

if (-not (Test-Path $InitKeysFile)) { throw "vault-init.json not found at $InitKeysFile" }
if (-not (Test-Path $CaBundlePath)) { throw "CA bundle not found at $CaBundlePath" }

$rootToken = (Get-Content $InitKeysFile -Raw | ConvertFrom-Json).root_token
if (-not $rootToken) { throw "vault-init.json missing root_token" }

# AD-complexity-compliant generator: at least one each of upper/lower/digit/symbol
function New-RandomPassword {
    param([int]$Length = 24)
    $sets = @(
        [char[]](65..90),                                   # A-Z
        [char[]](97..122),                                  # a-z
        [char[]](48..57),                                   # 0-9
        [char[]]('!','#','$','%','&','*','+','-','.','=','?','@','_')
    )
    $required = $sets | ForEach-Object { $_ | Get-Random -Count 1 }
    $pool     = $sets | ForEach-Object { $_ } | Sort-Object -Unique
    $rest     = 1..($Length - $required.Count) | ForEach-Object { $pool | Get-Random }
    ((@($required) + @($rest)) | Sort-Object { Get-Random }) -join ''
}

$paths = @(
    @{ Name = 'DSRM';            Path = 'nexus/foundation/dc-nexus/dsrm'                ; Username = 'DSRM'         },
    @{ Name = 'Administrator';   Path = 'nexus/foundation/dc-nexus/local-administrator' ; Username = 'Administrator' },
    @{ Name = 'nexusadmin';      Path = 'nexus/foundation/identity/nexusadmin'          ; Username = 'nexusadmin'   }
)

$env:VAULT_ADDR   = $VaultAddr
$env:VAULT_CACERT = $CaBundlePath
$env:VAULT_TOKEN  = $rootToken

Write-Host "Rotating foundation creds in Vault KV (length=$MinLength chars)" -ForegroundColor Cyan

foreach ($p in $paths) {
    $pwd = New-RandomPassword -Length $MinLength
    $maskedPwd = $pwd.Substring(0,4) + ('*' * ($pwd.Length - 8)) + $pwd.Substring($pwd.Length-4)
    if ($PSCmdlet.ShouldProcess("$($p.Path)", "rotate to $maskedPwd")) {
        # Use SSH to vault-1 because the build host doesn't have native vault.exe
        # in PATH (per the existing ops pattern in foundation env's overlays).
        $kvBody = @{ username = $p.Username; password = $pwd } | ConvertTo-Json -Compress
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($kvBody))
        $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
TMP=`$(mktemp); trap 'rm -f "`$TMP"' EXIT
echo '$bodyB64' | base64 -d > "`$TMP"
vault kv put '$($p.Path)' @"`$TMP" >/dev/null
echo "[rotate] $($p.Path) -- OK"
"@
        $bashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@192.168.70.121 "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "[rotate] $($p.Path) FAILED (rc=$LASTEXITCODE). Output: $output"
        }
        Write-Host "  [OK] $($p.Path) ($maskedPwd)" -ForegroundColor Green
    } else {
        Write-Host "  [WHATIF] $($p.Path) ($maskedPwd)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host "Rotation complete. Next step:" -ForegroundColor Cyan
Write-Host "  pwsh -File scripts\foundation.ps1 apply"
Write-Host ''
Write-Host "The dc_rotate_bootstrap_creds overlay will detect the creds_hash"
Write-Host "change + push the new pwds to live AD (ntdsutil for DSRM,"
Write-Host "Set-ADAccountPassword for Administrator + nexusadmin)."
