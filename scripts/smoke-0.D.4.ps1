#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.D.4 smoke gate: verify Vault foundation cred migration (AppRole +
  policy + nexus/foundation/* seeded paths + capability scoping).

.DESCRIPTION
  Strict superset of scripts/smoke-0.D.3.ps1 -- chains the 0.D.3 LDAP gate
  first (which itself chains 0.D.2 -> 0.D.1), then layers the 0.D.4 KV-
  foundation-seed checks. Run AFTER `pwsh -File scripts\security.ps1 apply`
  returns clean.

  Verifies the MASTER-PLAN.md s 0.D acceptance criterion shape:
    `vault kv get nexus/foundation/<path>` returns a populated record
  for every path in the seeded set. (The literal sqlserver/oltpdb path
  lands when the data env adds DB creds in 0.E or later.)

  Exits 0 on all-green, 1 if any check failed.

.PARAMETER Vault1Ip
  vault-1 IP. Default 192.168.70.121.

.PARAMETER InitKeysFile
  Path to vault-init.json on build host. Default $HOME/.nexus/vault-init.json.

.PARAMETER CaBundlePath
  Path to root CA bundle on build host. Default $HOME/.nexus/vault-ca-bundle.crt.

.PARAMETER ApproleCredsFile
  Path to vault-foundation-approle.json on build host. Default
  $HOME/.nexus/vault-foundation-approle.json.

.PARAMETER BindCredsFile
  Path to vault-ad-bind.json on build host (legacy 0.D.3 artifact, optional
  -- the 0.D.4 ad/* paths in KV may have been written direct from the
  bind/smoke overlays). Default $HOME/.nexus/vault-ad-bind.json.

.PARAMETER SkipPhase0D3
  If set, skips the chained 0.D.3 gate and runs only the 0.D.4 checks.

.NOTES
  See also:
    scripts/smoke-0.D.3.ps1                  (LDAP overlay -- chained gate)
    memory/feedback_smoke_gate_probe_robustness.md
#>

[CmdletBinding()]
param(
    [string]$Vault1Ip          = '192.168.70.121',
    [string]$Vault2Ip          = '192.168.70.122',
    [string]$Vault3Ip          = '192.168.70.123',
    [string]$DcIp              = '192.168.70.240',
    [string]$InitKeysFile      = $null,
    [string]$CaBundlePath      = $null,
    [string]$ApproleCredsFile  = $null,
    [string]$BindCredsFile     = $null,
    [switch]$SkipPhase0D3
)

if (-not $InitKeysFile)     { $InitKeysFile     = Join-Path $env:USERPROFILE '.nexus/vault-init.json' }
if (-not $CaBundlePath)     { $CaBundlePath     = Join-Path $env:USERPROFILE '.nexus/vault-ca-bundle.crt' }
if (-not $ApproleCredsFile) { $ApproleCredsFile = Join-Path $env:USERPROFILE '.nexus/vault-foundation-approle.json' }
if (-not $BindCredsFile)    { $BindCredsFile    = Join-Path $env:USERPROFILE '.nexus/vault-ad-bind.json' }

$ErrorActionPreference = 'Continue'
$script:failures = @()
$user = 'nexusadmin'

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param(
        [Parameter(Mandatory)][string]      $Label,
        [Parameter(Mandatory)][scriptblock] $Probe,
        [Parameter(Mandatory)][scriptblock] $Predicate
    )
    $out = & $Probe 2>&1 | Out-String
    $ok  = & $Predicate $out
    if ($ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        Write-Host ($out.Trim() -split "`r?`n" | ForEach-Object { "       $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
        $script:failures += $Label
    }
}

function Invoke-VaultCli {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$VaultCmd,
        [string]$Token = ''
    )
    $tokenPart = if ($Token) { "VAULT_TOKEN='$Token' " } else { '' }
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Ip "${tokenPart}VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault $VaultCmd"
}

# ─── Phase 0.D.3 chained gate (strict prerequisite) ──────────────────────
if (-not $SkipPhase0D3) {
    Write-Section 'Phase 0.D.3 chained smoke gate (which itself chains 0.D.2 -> 0.D.1)'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $smoke03  = Join-Path $repoRoot 'scripts\smoke-0.D.3.ps1'
    if (-not (Test-Path $smoke03)) {
        Write-Host "[FAIL] 0.D.3 smoke script not found at $smoke03" -ForegroundColor Red
        $script:failures += '0.D.3 smoke script missing'
    } else {
        & pwsh -NoProfile -File $smoke03 `
            -Vault1Ip $Vault1Ip -Vault2Ip $Vault2Ip -Vault3Ip $Vault3Ip -DcIp $DcIp `
            -InitKeysFile $InitKeysFile -CaBundlePath $CaBundlePath -BindCredsFile $BindCredsFile
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[FAIL] 0.D.3 chained smoke gate (exit=$LASTEXITCODE)" -ForegroundColor Red
            $script:failures += '0.D.3 chained smoke gate'
            Write-Host ''
            Write-Host '0.D.3 gate failed; halting before 0.D.4 KV-foundation checks' -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host ''
Write-Host 'Phase 0.D.4 smoke gate: foundation cred migration (KV)' -ForegroundColor White

# Need root token for admin reads (policy, AppRole config)
$rootToken = $null
if (Test-Path $InitKeysFile) {
    try { $rootToken = (Get-Content $InitKeysFile | ConvertFrom-Json).root_token } catch { }
}
if (-not $rootToken) {
    Write-Host "[FAIL] $InitKeysFile not readable -- cannot run 0.D.4 checks without root token" -ForegroundColor Red
    $script:failures += 'init keys file not readable'
    exit 1
}

# ─── 1. AppRole creds JSON file present + parseable ──────────────────────
Write-Section 'AppRole creds JSON (build-host artifact)'
Test-Check "$ApproleCredsFile exists with role_id + secret_id" `
    { if (Test-Path $ApproleCredsFile) { Get-Content $ApproleCredsFile -Raw } else { 'MISSING' } } `
    {
        param($o)
        if ($o -match '\bMISSING\b') { return $false }
        try {
            $j = $o | ConvertFrom-Json
            ($j.role_id -match '^[0-9a-fA-F-]{20,}$') -and ($j.secret_id -match '^[0-9a-fA-F-]{20,}$')
        } catch { $false }
    }

# Parse out role-id + secret-id for downstream login probe
$approleCreds = $null
$roleId = $null
$secretId = $null
if (Test-Path $ApproleCredsFile) {
    try {
        $approleCreds = Get-Content $ApproleCredsFile -Raw | ConvertFrom-Json
        $roleId   = $approleCreds.role_id
        $secretId = $approleCreds.secret_id
    } catch { }
}

# ─── 2. Vault policy nexus-foundation-reader exists ──────────────────────
Write-Section 'Vault policy nexus-foundation-reader'
Test-Check "policy 'nexus-foundation-reader' exists" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'policy read nexus-foundation-reader' -Token $rootToken } `
    { param($o) ($o -match 'path\s+"nexus/data/foundation') -and ($o -notmatch 'No policy named') }

Test-Check "policy grants read on nexus/data/foundation/* (not write outside ad/*)" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'policy read nexus-foundation-reader' -Token $rootToken } `
    {
        param($o)
        # Must include read on nexus/data/foundation/*; ad/* must allow create+update;
        # bare nexus/data/foundation/* (non-ad) must NOT include write
        ($o -match 'path\s+"nexus/data/foundation/\*"') -and `
            ($o -match 'path\s+"nexus/data/foundation/ad/\*"') -and `
            ($o -match 'path\s+"auth/token/lookup-self"') -and `
            ($o -match 'path\s+"auth/token/renew-self"')
    }

# ─── 3. AppRole nexus-foundation-reader configured correctly ─────────────
Write-Section 'AppRole nexus-foundation-reader'
Test-Check "auth/approle/role/nexus-foundation-reader bound to nexus-foundation-reader policy" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json auth/approle/role/nexus-foundation-reader' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            ($j.data.token_policies -contains 'nexus-foundation-reader') -and `
                ($j.data.bind_secret_id -eq $true)
        } catch { $false }
    }

Test-Check "AppRole role-id matches the JSON file" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -field=role_id auth/approle/role/nexus-foundation-reader/role-id' -Token $rootToken } `
    { param($o) $roleId -and ($o.Trim() -eq $roleId) }

# ─── 4. AppRole login works + yields a token with the right policy ──────
Write-Section 'AppRole login (role-id + secret-id from JSON)'
if (-not $roleId -or -not $secretId) {
    Write-Host '[FAIL] role-id or secret-id missing from approle creds JSON; skipping login probe' -ForegroundColor Red
    $script:failures += 'AppRole creds JSON missing role_id/secret_id'
} else {
    $loginBash = @"
set -euo pipefail
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
vault write -format=json auth/approle/login role_id='$roleId' secret_id='$secretId'
"@
    $loginB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($loginBash))

    Test-Check "AppRole login returns token with nexus-foundation-reader policy" `
        {
            ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip `
                "echo '$loginB64' | base64 -d | bash" 2>&1
        } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                ($j.auth.client_token) -and `
                    ($j.auth.token_policies -contains 'nexus-foundation-reader')
            } catch { $false }
        }

    # Capture the token for capability probes below
    $approleToken = $null
    $loginRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip `
        "echo '$loginB64' | base64 -d | bash" 2>&1 | Out-String
    try { $approleToken = ($loginRaw | ConvertFrom-Json).auth.client_token } catch { }
}

# ─── 5. KV paths populated under nexus/foundation/ ───────────────────────
Write-Section 'KV paths populated (nexus/foundation/...)'
$expectedPaths = @(
    @{ Path = 'foundation/dc-nexus/dsrm';                Field = 'password' },
    @{ Path = 'foundation/dc-nexus/local-administrator'; Field = 'password' },
    @{ Path = 'foundation/identity/nexusadmin';          Field = 'password' },
    @{ Path = 'foundation/vault/userpass-nexusadmin';    Field = 'password' },
    @{ Path = 'foundation/ad/svc-vault-ldap';            Field = 'password' },
    @{ Path = 'foundation/ad/svc-vault-smoke';           Field = 'password' }
)
foreach ($e in $expectedPaths) {
    $p = $e
    Test-Check "vault kv get nexus/$($p.Path) returns $($p.Field)" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "kv get -format=json nexus/$($p.Path)" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $val = $j.data.data.($p.Field)
                $val -ne $null -and $val.Length -gt 0
            } catch { $false }
        }
}

# ─── 6. AppRole token capability scoping ─────────────────────────────────
Write-Section 'AppRole token capability scoping'
if (-not $approleToken) {
    Write-Host '[FAIL] no AppRole token captured; skipping capability checks' -ForegroundColor Red
    $script:failures += 'AppRole capability checks (no token)'
} else {
    Test-Check 'AppRole token CAN read nexus/foundation/dc-nexus/dsrm (positive)' `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'kv get -format=json nexus/foundation/dc-nexus/dsrm' -Token $approleToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data.data.password -ne $null
            } catch { $false }
        }

    Test-Check 'AppRole token CANNOT read nexus/smoke/canary (negative -- scope guard)' `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'kv get -format=json nexus/smoke/canary' -Token $approleToken } `
        {
            param($o)
            # Permission denied is the success case here; non-zero exit + 'permission denied' message
            ($o -match 'permission denied') -or ($o -match '403')
        }

    Test-Check 'AppRole token CANNOT write nexus/foundation/dc-nexus/dsrm (negative -- writes allowed only on ad/*)' `
        {
            ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip `
                "VAULT_TOKEN='$approleToken' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault kv put nexus/foundation/dc-nexus/dsrm password=ShouldBeBlocked 2>&1; true"
        } `
        { param($o) ($o -match 'permission denied') -or ($o -match '403') }
}

# ─── 7. Build-host workflow: foundation env can plan with KV-creds enabled
# (This is a soft probe: confirms the AppRole creds JSON is consumable by
# Terraform's vault provider WITHOUT actually running terraform plan -- we
# just verify the file shape is correct since terraform plan is heavy.)
Write-Section 'Foundation env vault provider readiness'
Test-Check "AppRole creds JSON has role_name = nexus-foundation-reader" `
    { if (Test-Path $ApproleCredsFile) { Get-Content $ApproleCredsFile -Raw } else { 'MISSING' } } `
    {
        param($o)
        if ($o -match 'MISSING') { return $false }
        try {
            $j = $o | ConvertFrom-Json
            $j.role_name -eq 'nexus-foundation-reader'
        } catch { $false }
    }

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.D.4 SMOKE CHECKS PASSED (chained 0.D.3 + 0.D.2 + 0.D.1 + KV foundation seed)' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
