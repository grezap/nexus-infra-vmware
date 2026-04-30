#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.D.3 smoke gate: verify Vault LDAP integration (auth/ldap +
  secrets/ldap + group->policy mappings + end-to-end LDAP login probe).

.DESCRIPTION
  Strict superset of scripts/smoke-0.D.2.ps1 -- chains the 0.D.2 PKI gate
  first (which itself chains 0.D.1), then layers the LDAP checks. Run AFTER
  `pwsh -File scripts\security.ps1 apply` returns clean AND the foundation
  env was applied with -Vars enable_vault_ad_integration=true.

  Exits 0 on all-green, 1 if any check failed.

  All probes follow memory/feedback_smoke_gate_probe_robustness.md:
    - openssl/jq do work on remote nodes; predicates use marker tokens + -match
    - sudo invocations get 2>/dev/null on the remote side
    - no [DateTime]::Parse on locale-sensitive output

.PARAMETER Vault1Ip
  vault-1 IP. Default 192.168.70.121 (canonical per vms.yaml).

.PARAMETER DcIp
  dc-nexus IP. Default 192.168.70.240 (foundation env's DHCP'd address).

.PARAMETER InitKeysFile
  Path to vault-init.json on build host. Default $HOME/.nexus/vault-init.json.

.PARAMETER CaBundlePath
  Path to root CA bundle on build host. Default $HOME/.nexus/vault-ca-bundle.crt.

.PARAMETER BindCredsFile
  Path to vault-ad-bind.json (binddn, bindpass, smoke creds) written by the
  foundation env. Default $HOME/.nexus/vault-ad-bind.json.

.PARAMETER AdminGroup / OperatorGroup / ReaderGroup
  Expected AD security group names. Defaults match foundation defaults.

.PARAMETER DemoRotateAccount
  Expected static-role / demo svc account name. Default svc-demo-rotated.

.PARAMETER CheckRotateRole
  If $true, runs the static-rotate-role + static-cred checks. Default $false
  because AD requires LDAPS/StartTLS for password-change operations (the
  rotate-role's first-apply write); plain LDAP/389 cannot rotate. Re-enable
  this check once 0.D.5 lands the LDAPS overlay.

.PARAMETER SkipPhase0D2
  If set, skips the chained 0.D.2 gate and runs only the 0.D.3 LDAP checks.
  Useful when iterating on LDAP overlays alone. Default $false.

.NOTES
  See also:
    docs/handbook.md s 1i                        (Phase 0.D.3 reference)
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
    [string]$BindCredsFile     = $null,
    [string]$AdminGroup        = 'nexus-vault-admins',
    [string]$OperatorGroup     = 'nexus-vault-operators',
    [string]$ReaderGroup       = 'nexus-vault-readers',
    [string]$DemoRotateAccount = 'svc-demo-rotated',
    [bool]  $CheckRotateRole   = $false,
    [switch]$SkipPhase0D2
)

if (-not $InitKeysFile)  { $InitKeysFile  = Join-Path $env:USERPROFILE '.nexus/vault-init.json' }
if (-not $CaBundlePath)  { $CaBundlePath  = Join-Path $env:USERPROFILE '.nexus/vault-ca-bundle.crt' }
if (-not $BindCredsFile) { $BindCredsFile = Join-Path $env:USERPROFILE '.nexus/vault-ad-bind.json' }

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

# ─── Phase 0.D.2 chained gate (strict prerequisite) ──────────────────────
if (-not $SkipPhase0D2) {
    Write-Section 'Phase 0.D.2 chained smoke gate (which itself chains 0.D.1)'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $smoke02  = Join-Path $repoRoot 'scripts\smoke-0.D.2.ps1'
    if (-not (Test-Path $smoke02)) {
        Write-Host "[FAIL] 0.D.2 smoke script not found at $smoke02" -ForegroundColor Red
        $script:failures += '0.D.2 smoke script missing'
    } else {
        & pwsh -NoProfile -File $smoke02 `
            -Vault1Ip $Vault1Ip -Vault2Ip $Vault2Ip -Vault3Ip $Vault3Ip `
            -InitKeysFile $InitKeysFile -CaBundlePath $CaBundlePath
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[FAIL] 0.D.2 chained smoke gate (exit=$LASTEXITCODE)" -ForegroundColor Red
            $script:failures += '0.D.2 chained smoke gate'
            Write-Host ''
            Write-Host '0.D.2 gate failed; halting before 0.D.3 LDAP checks' -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host ''
Write-Host 'Phase 0.D.3 smoke gate: LDAP overlay' -ForegroundColor White

# Need root token for Vault config reads
$rootToken = $null
if (Test-Path $InitKeysFile) {
    try { $rootToken = (Get-Content $InitKeysFile | ConvertFrom-Json).root_token } catch { }
}
if (-not $rootToken) {
    Write-Host "[FAIL] $InitKeysFile not readable -- cannot run LDAP checks without root token" -ForegroundColor Red
    $script:failures += 'init keys file not readable'
    exit 1
}

# Need bind cred file for the smoke login probe
$bindCreds = $null
if (Test-Path $BindCredsFile) {
    try { $bindCreds = Get-Content $BindCredsFile | ConvertFrom-Json } catch { }
}
if (-not $bindCreds -or -not $bindCreds.smoke_username -or -not $bindCreds.smoke_password) {
    Write-Host "[FAIL] $BindCredsFile missing or lacks smoke_username/smoke_password -- run foundation env with enable_vault_ad_integration=true" -ForegroundColor Red
    $script:failures += 'vault-ad-bind.json missing smoke creds'
    exit 1
}

# ─── 1. DC reachability for LDAP from vault-1 ────────────────────────────
Write-Section 'DC reachability (vault-1 -> dc-nexus on TCP/389)'
Test-Check "vault-1 can reach dc-nexus:389 (LDAP)" `
    {
        ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip `
            "timeout 5 bash -c '</dev/tcp/$DcIp/389' 2>/dev/null && echo LDAP_OPEN || echo LDAP_BLOCKED"
    } `
    { param($o) $o -match '\bLDAP_OPEN\b' }

# ─── 2. auth/ldap method enabled + configured ────────────────────────────
Write-Section 'Vault auth/ldap'
Test-Check 'auth/ldap method enabled' `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'auth list -format=json' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            ($j.PSObject.Properties | Where-Object { $_.Name -eq 'ldap/' }) -ne $null
        } catch { $false }
    }

Test-Check 'auth/ldap config has expected url + binddn (no bindpass leak)' `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json auth/ldap/config' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            ($j.data.url -match 'ldap://') -and `
            ($j.data.binddn -match 'svc-vault-ldap') -and `
            (-not $j.data.bindpass)   # bindpass should never be returned in reads
        } catch { $false }
    }

# ─── 3. Group -> policy mappings ─────────────────────────────────────────
Write-Section 'auth/ldap group mappings'
foreach ($pair in @(
        @{ Group = $AdminGroup;    ExpectedPolicy = 'nexus-admin'    },
        @{ Group = $OperatorGroup; ExpectedPolicy = 'nexus-operator' },
        @{ Group = $ReaderGroup;   ExpectedPolicy = 'nexus-reader'   }
    )) {
    $p = $pair
    Test-Check "auth/ldap/groups/$($p.Group) -> $($p.ExpectedPolicy)" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "read -format=json auth/ldap/groups/$($p.Group)" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data.policies -contains $p.ExpectedPolicy
            } catch { $false }
        }
}

# ─── 4. Policies are actually defined ────────────────────────────────────
Write-Section 'Vault policies defined'
foreach ($policy in @('nexus-admin', 'nexus-operator', 'nexus-reader')) {
    $polRef = $policy
    Test-Check "policy '$polRef' exists" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "policy read $polRef" -Token $rootToken } `
        { param($o) $o -match 'path\s+"' -and $o -notmatch 'No policy named' }
}

# ─── 5. End-to-end LDAP login probe ──────────────────────────────────────
Write-Section 'End-to-end LDAP login (svc-vault-smoke -> nexus-reader policy)'
$smokeUser = $bindCreds.smoke_username
$smokePass = $bindCreds.smoke_password

# Avoid shell-escape issues entirely by base64-transiting the password to the
# remote node, decoding it into a tmpfile, then using Vault's `@file` field
# syntax to read the value from the file. No layer of the pipeline (PS string
# interpolation, ssh.exe argv, remote bash tokenization, vault CLI argv) ever
# sees the raw password chars in a context where they could be mangled.
$pwdB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($smokePass))
$userB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($smokeUser))

Test-Check "$smokeUser can login via auth/ldap and gets token" `
    {
        $remoteScript = @"
set -euo pipefail
TMPPWD=`$(mktemp)
trap 'rm -f "`$TMPPWD"' EXIT
echo '$pwdB64' | base64 -d > "`$TMPPWD"
USERNAME=`$(echo '$userB64' | base64 -d)
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
vault login -format=json -method=ldap username="`$USERNAME" password=@"`$TMPPWD"
"@
        $scriptB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteScript))
        ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip `
            "echo '$scriptB64' | base64 -d | bash" 2>&1
    } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            ($j.auth.client_token -and $j.auth.policies -contains 'nexus-reader')
        } catch { $false }
    }

# Diagnostic block -- only emits if the previous check failed. Surfaces enough
# cred-fingerprint info to verify JSON-vs-AD-pwd match without leaking the
# actual password. Also probes AD for account state (Enabled, LockedOut,
# PasswordExpired) which would explain a bind-rejection that's not a pwd
# mismatch (e.g. AD lockout from too many failed login attempts during
# iteration). Bind-as-user via ldapsearch from vault-1 isolates whether
# the failure is at AD's auth layer or somewhere in Vault's path.
if ($script:failures.Count -gt 0 -and $script:failures[-1] -match 'can login via auth/ldap') {
    Write-Section 'Login failure diagnostic (no password leak)'
    $pwdHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.UTF8Encoding]::new($false).GetBytes($smokePass)
        )
    ).Replace('-','').ToLower().Substring(0,12)
    Write-Host "  Smoke account:        $smokeUser" -ForegroundColor DarkGray
    Write-Host "  JSON pwd length:      $($smokePass.Length)" -ForegroundColor DarkGray
    Write-Host "  JSON pwd SHA256[:12]: $pwdHash" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '  AD account state (via dc-nexus):' -ForegroundColor DarkGray
    $adProbe = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@192.168.70.240 `
        "powershell -NoProfile -Command `"(Get-ADUser -Identity '$smokeUser' -Properties Enabled, LockedOut, PasswordExpired, PasswordLastSet) | Select-Object SamAccountName, Enabled, LockedOut, PasswordExpired, PasswordLastSet | Format-List`"" 2>&1
    Write-Host ($adProbe | Out-String -Width 200) -ForegroundColor DarkGray

    Write-Host '  Direct PS bind probe via Get-ADUser -Credential on dc-nexus (using JSON pwd via base64 transit):' -ForegroundColor DarkGray
    # Use UTF-16-LE base64 for Windows PowerShell EncodedCommand on the DC.
    $psScript = @"
`$pwdB64 = '$pwdB64'
`$pwd = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$pwdB64))
`$cred = New-Object System.Management.Automation.PSCredential('$smokeUser', (ConvertTo-SecureString `$pwd -AsPlainText -Force))
try {
    `$u = Get-ADUser -Identity '$smokeUser' -Credential `$cred -ErrorAction Stop
    Write-Output ('BIND_OK:' + `$u.DistinguishedName)
} catch {
    Write-Output ('BIND_FAILED: ' + `$_.Exception.Message)
}
"@
    $psB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psScript))
    $bindOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@192.168.70.240 `
        "powershell -NoProfile -EncodedCommand $psB64" 2>&1
    Write-Host ($bindOut | Out-String -Width 200) -ForegroundColor DarkGray
    Write-Host '  ^ BIND_OK: JSON pwd matches AD; failure is in Vaults LDAP code path or transit between Vault and AD.' -ForegroundColor DarkGray
    Write-Host '  ^ BIND_FAILED + "user name or password is incorrect": JSON pwd does NOT match AD.' -ForegroundColor DarkGray
    Write-Host '  ^ If AD state above shows LockedOut=True: account locked; SSH dc-nexus and run "Unlock-ADAccount svc-vault-smoke".' -ForegroundColor DarkGray

    # If BIND_OK confirmed the pwd is fine, dump Vault's view of the LDAP config
    # + tail vault.service journal to see what Vault is actually doing.
    if ($bindOut -match 'BIND_OK:') {
        Write-Host ''
        Write-Host '  Vault auth/ldap config (as Vault sees it; bindpass redacted):' -ForegroundColor DarkGray
        $configDump = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip `
            "VAULT_TOKEN='$rootToken' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault read -format=json auth/ldap/config 2>&1 | jq '.data | del(.bindpass)'" 2>&1
        Write-Host ($configDump | Out-String -Width 200) -ForegroundColor DarkGray

        Write-Host '  vault.service journal (last 10 LDAP-related lines):' -ForegroundColor DarkGray
        $journalDump = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip `
            "sudo journalctl -u vault.service --since '5 minutes ago' --no-pager 2>/dev/null | grep -iE 'ldap|bind|auth.*fail' | tail -10" 2>&1
        Write-Host ($journalDump | Out-String -Width 200) -ForegroundColor DarkGray
        Write-Host '  ^ If journal shows specific bind errors (DN, ldap result code), they pinpoint the issue.' -ForegroundColor DarkGray
        Write-Host '  ^ If config dump shows wrong userdn/userattr/groupdn, the auth/ldap overlay needs a fix.' -ForegroundColor DarkGray
    }
}

# ─── 6. secrets/ldap engine mounted + configured ─────────────────────────
Write-Section 'Vault secrets/ldap engine'
Test-Check 'secrets/ldap mounted (schema=ad)' `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'secrets list -format=json' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            $m = $j.PSObject.Properties | Where-Object { $_.Name -eq 'ldap/' }
            $m -and $m.Value.type -eq 'ldap'
        } catch { $false }
    }

Test-Check 'ldap/config has schema=ad + password_policy=nexus-ad-rotated' `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json ldap/config' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            ($j.data.schema -eq 'ad') -and ($j.data.password_policy -eq 'nexus-ad-rotated')
        } catch { $false }
    }

# ─── 7. Static rotate-role + cred lookup (skipped by default -- requires LDAPS) ─────
Write-Section 'Static rotate-role for demo AD account'
if (-not $CheckRotateRole) {
    Write-Host "[SKIP] static-role + static-cred checks -- AD requires LDAPS/StartTLS for password-change operations" -ForegroundColor Yellow
    Write-Host "[SKIP] re-enable once 0.D.5 LDAPS overlay lands (vault_ldap_url -> ldaps://...:636 + DC cert)" -ForegroundColor Yellow
    Write-Host "[SKIP] to run these checks anyway: pwsh -File scripts\smoke-0.D.3.ps1 -CheckRotateRole `$true" -ForegroundColor Yellow
} else {
    Test-Check "ldap/static-role/$DemoRotateAccount exists" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "read -format=json ldap/static-role/$DemoRotateAccount" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data.username -eq $DemoRotateAccount
            } catch { $false }
        }

    Test-Check "ldap/static-cred/$DemoRotateAccount returns current Vault-managed password" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "read -format=json ldap/static-cred/$DemoRotateAccount" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                ($j.data.username -eq $DemoRotateAccount) -and `
                ([string]::IsNullOrEmpty($j.data.password) -eq $false) -and `
                ($j.data.last_vault_rotation)
            } catch { $false }
        }
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.D.3 SMOKE CHECKS PASSED (chained 0.D.2 + 0.D.1 + LDAP overlay)' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
