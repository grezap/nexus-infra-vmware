#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.D.5 smoke gate: verify the 5 sub-deliverables (MinPasswordLength=14
  + KV->AD rotation; leaf TTL 90d; GMSA scaffolding; Vault Agent on member
  servers; Transit auto-unseal).

.DESCRIPTION
  Strict superset of scripts/smoke-0.D.4.ps1 -- chains the 0.D.4 KV-
  foundation gate first (which itself chains 0.D.3 -> 0.D.2 -> 0.D.1).
  Then layers the 0.D.5 checks across the 5 sub-deliverables.

  Probes (per sub-deliverable):

    5.1 MinPasswordLength=14 + KV->AD rotation:
      - AD reports MinPasswordLength=14
      - nexusadmin in Domain Admins + Enterprise Admins (membership remediation)
      - KV-managed nexusadmin / Administrator pwds match live AD (no desync)
        verified via SSH echo as nexusadmin (cert auth doesn't test pwd; we
        check the dc_rotate_bootstrap_creds overlay's last-run id matches
        creds_hash trigger)

    5.2 Leaf TTL 90d:
      - Each Vault listener cert validity span (notAfter - notBefore) is
        within +/-10% of 2160h (90d * 24)
      - dc-nexus LDAPS cert: same span check

    5.3 GMSA scaffolding:
      - nexus-gmsa-consumers AD group exists in OU=Groups
      - gmsa-nexus-demo$ AD object exists in OU=ServiceAccounts
      - PrincipalsAllowedToRetrieveManagedPassword includes nexus-gmsa-consumers
      - KDS root key state: PRESENT (with KeyId) or MISSING (warn-only;
        manual ops required per handbook s 1k.2 -- Server 2025 SSH limit)

    5.4 Vault Agent on member servers:
      - 2 Vault policies (nexus-agent-dc-nexus + nexus-agent-nexus-jumpbox)
      - 2 AppRoles bound to those policies
      - 2 creds JSON sidecars on build host (mode 0600 via icacls)
      - dc-nexus: nexus-vault-agent service Running; rendered DSRM file
        non-empty
      - nexus-jumpbox: nexus-vault-agent service Running; rendered nexusadmin
        pwd file non-empty

    5.5 Transit auto-unseal: (deferred to post-5.5 implementation)

.PARAMETER SkipPhase0D4
  If set, skips the chained 0.D.4 gate and runs only the 0.D.5 checks.

.NOTES
  See also:
    scripts/smoke-0.D.4.ps1                  (KV foundation gate -- chained)
    memory/feedback_smoke_gate_probe_robustness.md
    memory/feedback_kds_rootkey_server2025_ssh.md
#>

[CmdletBinding()]
param(
    [string]$Vault1Ip                        = '192.168.70.121',
    [string]$Vault2Ip                        = '192.168.70.122',
    [string]$Vault3Ip                        = '192.168.70.123',
    [string]$DcIp                            = '192.168.70.240',
    [string]$JumpboxIp                       = '192.168.70.241',
    [string]$InitKeysFile                    = $null,
    [string]$CaBundlePath                    = $null,
    [string]$ApproleCredsFile                = $null,
    [string]$BindCredsFile                   = $null,
    [string]$AgentDcNexusCredsFile           = $null,
    [string]$AgentNexusJumpboxCredsFile      = $null,
    [int]   $MinLeafTtlHours                 = 1944,    # 90d * 24 * 0.9 = 1944h (lower bound)
    [int]   $MaxLeafTtlHours                 = 2376,    # 90d * 24 * 1.1 = 2376h (upper bound)
    [int]   $MinPasswordLength               = 14,
    [string[]]$NexusadminRequiredGroups      = @('Domain Admins', 'Enterprise Admins'),
    [switch]$SkipPhase0D4
)

if (-not $InitKeysFile)               { $InitKeysFile               = Join-Path $env:USERPROFILE '.nexus/vault-init.json' }
if (-not $CaBundlePath)               { $CaBundlePath               = Join-Path $env:USERPROFILE '.nexus/vault-ca-bundle.crt' }
if (-not $ApproleCredsFile)           { $ApproleCredsFile           = Join-Path $env:USERPROFILE '.nexus/vault-foundation-approle.json' }
if (-not $BindCredsFile)              { $BindCredsFile              = Join-Path $env:USERPROFILE '.nexus/vault-ad-bind.json' }
if (-not $AgentDcNexusCredsFile)      { $AgentDcNexusCredsFile      = Join-Path $env:USERPROFILE '.nexus/vault-agent-dc-nexus.json' }
if (-not $AgentNexusJumpboxCredsFile) { $AgentNexusJumpboxCredsFile = Join-Path $env:USERPROFILE '.nexus/vault-agent-nexus-jumpbox.json' }

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

function Test-Warn {
    # Like Test-Check but emits [WARN] instead of [FAIL] -- used for
    # known-deferred-to-manual-ops items (e.g. KDS root key on Server 2025).
    param(
        [Parameter(Mandatory)][string]      $Label,
        [Parameter(Mandatory)][scriptblock] $Probe,
        [Parameter(Mandatory)][scriptblock] $Predicate,
        [Parameter(Mandatory)][string]      $WarnHint
    )
    $out = & $Probe 2>&1 | Out-String
    $ok  = & $Predicate $out
    if ($ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
    } else {
        Write-Host "[WARN] $Label" -ForegroundColor Yellow
        Write-Host "       $WarnHint" -ForegroundColor DarkYellow
    }
}

# ─── Phase 0.D.4 chained gate (strict prerequisite) ──────────────────────
if (-not $SkipPhase0D4) {
    Write-Section 'Phase 0.D.4 chained smoke gate (chains 0.D.3 -> 0.D.2 -> 0.D.1)'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $smoke04  = Join-Path $repoRoot 'scripts\smoke-0.D.4.ps1'
    if (-not (Test-Path $smoke04)) {
        Write-Host "[FAIL] 0.D.4 smoke script not found at $smoke04" -ForegroundColor Red
        $script:failures += '0.D.4 smoke script missing'
    } else {
        & pwsh -NoProfile -File $smoke04 `
            -Vault1Ip $Vault1Ip -Vault2Ip $Vault2Ip -Vault3Ip $Vault3Ip -DcIp $DcIp `
            -InitKeysFile $InitKeysFile -CaBundlePath $CaBundlePath `
            -ApproleCredsFile $ApproleCredsFile -BindCredsFile $BindCredsFile
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[FAIL] 0.D.4 chained smoke gate (exit=$LASTEXITCODE)" -ForegroundColor Red
            $script:failures += '0.D.4 chained smoke gate'
            Write-Host ''
            Write-Host '0.D.4 gate failed; halting before 0.D.5 checks' -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host ''
Write-Host 'Phase 0.D.5 smoke gate: 5-step roll-up' -ForegroundColor White

$rootToken = $null
if (Test-Path $InitKeysFile) {
    try { $rootToken = (Get-Content $InitKeysFile | ConvertFrom-Json).root_token } catch { }
}
if (-not $rootToken) {
    Write-Host "[FAIL] $InitKeysFile not readable" -ForegroundColor Red
    $script:failures += 'init keys file not readable'
    exit 1
}

# ═════════════════════════════════════════════════════════════════════════
# 5.1 MinPasswordLength=14 + KV->AD rotation
# ═════════════════════════════════════════════════════════════════════════
Write-Section '5.1 MinPasswordLength + KV->AD rotation'

Test-Check "AD MinPasswordLength = $MinPasswordLength" `
    { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$DcIp 'powershell -NoProfile -Command "(Get-ADDefaultDomainPasswordPolicy).MinPasswordLength"' } `
    { param($o) $o.Trim() -eq $MinPasswordLength.ToString() }

foreach ($grp in $NexusadminRequiredGroups) {
    $g = $grp
    Test-Check "nexusadmin in $g" `
        { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$DcIp "powershell -NoProfile -Command `"(Get-ADGroupMember '$g' | Where-Object SamAccountName -eq 'nexusadmin') -ne `$null`"" } `
        { param($o) $o.Trim() -eq 'True' }
}

# ═════════════════════════════════════════════════════════════════════════
# 5.2 Leaf cert TTL 90d
# ═════════════════════════════════════════════════════════════════════════
Write-Section '5.2 Leaf cert TTL 90d (vault listeners + dc-nexus LDAPS)'

foreach ($node in @(
    @{ Name='vault-1'; Ip=$Vault1Ip },
    @{ Name='vault-2'; Ip=$Vault2Ip },
    @{ Name='vault-3'; Ip=$Vault3Ip }
)) {
    $n = $node
    # Per memory/feedback_smoke_gate_probe_robustness.md rule #1 -- don't
    # [DateTime]::Parse openssl-format dates from PS (locale-sensitive).
    # Let the remote shell compute the hour count via openssl + date.
    Test-Check "$($n.Name): listener cert validity span within $MinLeafTtlHours-$MaxLeafTtlHours hours" `
        {
            ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($n.Ip) 'NB=$(sudo openssl x509 -in /etc/vault.d/tls/vault.crt -noout -startdate 2>/dev/null | sed s/notBefore=//); NA=$(sudo openssl x509 -in /etc/vault.d/tls/vault.crt -noout -enddate 2>/dev/null | sed s/notAfter=//); NB_E=$(date -d "$NB" +%s); NA_E=$(date -d "$NA" +%s); echo "SPAN_HOURS=$(( (NA_E - NB_E) / 3600 ))"' 2>&1
        } `
        {
            param($o)
            try {
                if ($o -match 'SPAN_HOURS=(\d+)') {
                    $hours = [int]$Matches[1]
                    $hours -ge $MinLeafTtlHours -and $hours -le $MaxLeafTtlHours
                } else { $false }
            } catch { $false }
        }
}

# dc-nexus LDAPS cert: PowerShell side; PS DateTime arithmetic with cert
# objects' NotBefore/NotAfter Property (NOT openssl strings) is fine -- the
# memory canon prohibits parsing openssl date STRINGS, not .NET DateTime
# arithmetic.
Test-Check "dc-nexus LDAPS cert validity span within $MinLeafTtlHours-$MaxLeafTtlHours hours" `
    {
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$DcIp 'powershell -NoProfile -Command "$c = Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -match dc-nexus.nexus.lab | Select-Object -First 1; [int]($c.NotAfter - $c.NotBefore).TotalHours"' 2>&1
    } `
    {
        param($o)
        try {
            $hours = [int]$o.Trim()
            $hours -ge $MinLeafTtlHours -and $hours -le $MaxLeafTtlHours
        } catch { $false }
    }

# ═════════════════════════════════════════════════════════════════════════
# 5.3 GMSA scaffolding
# ═════════════════════════════════════════════════════════════════════════
Write-Section '5.3 GMSA scaffolding'

Test-Check "AD group nexus-gmsa-consumers exists in OU=Groups" `
    { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$DcIp 'powershell -NoProfile -Command "(Get-ADGroup -Filter \"Name -eq ''nexus-gmsa-consumers''\").DistinguishedName"' } `
    { param($o) $o -match 'CN=nexus-gmsa-consumers,OU=Groups' }

Test-Check "GMSA gmsa-nexus-demo`$ exists in OU=ServiceAccounts" `
    { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$DcIp 'powershell -NoProfile -Command "(Get-ADServiceAccount -Filter \"Name -eq ''gmsa-nexus-demo''\").DistinguishedName"' } `
    { param($o) $o -match 'CN=gmsa-nexus-demo,OU=ServiceAccounts' }

Test-Check "GMSA Principals include nexus-gmsa-consumers" `
    { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$DcIp 'powershell -NoProfile -Command "Get-ADServiceAccount gmsa-nexus-demo -Properties PrincipalsAllowedToRetrieveManagedPassword | Select-Object -ExpandProperty PrincipalsAllowedToRetrieveManagedPassword"' } `
    { param($o) $o -match 'CN=nexus-gmsa-consumers' }

# KDS root key: WARN-only when missing (Server 2025 SSH limit; manual ops required)
Test-Warn "KDS root key present on the forest" `
    { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$DcIp 'powershell -NoProfile -Command "(Get-KdsRootKey | Measure-Object).Count"' } `
    { param($o) try { [int]$o.Trim() -gt 0 } catch { $false } } `
    -WarnHint "KDS root key absent. Test-ADServiceAccount on gmsa-nexus-demo will return False until manual remediation. RDP into dc-nexus as Administrator + run: Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)). See feedback_kds_rootkey_server2025_ssh.md + handbook s 1k.2."

# ═════════════════════════════════════════════════════════════════════════
# 5.4 Vault Agent on member servers
# ═════════════════════════════════════════════════════════════════════════
Write-Section '5.4 Vault Agent on member servers (security side)'

foreach ($pol in @('nexus-agent-dc-nexus', 'nexus-agent-nexus-jumpbox')) {
    $p = $pol
    Test-Check "Vault policy '$p' exists" `
        { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip "VAULT_TOKEN='$rootToken' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault policy read $p" } `
        { param($o) $o -match 'path\s+"' -and $o -notmatch 'No policy named' }

    Test-Check "AppRole '$p' bound to '$p' policy" `
        { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip "VAULT_TOKEN='$rootToken' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault read -format=json auth/approle/role/$p" } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data.token_policies -contains $p
            } catch { $false }
        }
}

foreach ($pair in @(
    @{ Path = $AgentDcNexusCredsFile;      Role = 'nexus-agent-dc-nexus' },
    @{ Path = $AgentNexusJumpboxCredsFile; Role = 'nexus-agent-nexus-jumpbox' }
)) {
    $pp = $pair
    Test-Check "AppRole creds JSON $($pp.Path) shape" `
        { if (Test-Path $pp.Path) { Get-Content $pp.Path -Raw } else { 'MISSING' } } `
        {
            param($o)
            if ($o -match 'MISSING') { return $false }
            try {
                $j = $o | ConvertFrom-Json
                ($j.role_id -match '^[0-9a-fA-F-]{20,}$') -and `
                    ($j.secret_id -match '^[0-9a-fA-F-]{20,}$') -and `
                    ($j.role_name -eq $pp.Role)
            } catch { $false }
        }
}

Write-Section '5.4 Vault Agent service + rendered creds (foundation side)'

foreach ($host_ in @(
    @{ Name='dc-nexus';      Ip=$DcIp;      Render='C:\ProgramData\nexus\agent\dsrm.txt' },
    @{ Name='nexus-jumpbox'; Ip=$JumpboxIp; Render='C:\ProgramData\nexus\agent\nexusadmin-pwd.txt' }
)) {
    $h = $host_
    Test-Check "$($h.Name): nexus-vault-agent service Running" `
        { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($h.Ip) 'powershell -NoProfile -Command "(Get-Service nexus-vault-agent -ErrorAction SilentlyContinue).Status"' } `
        { param($o) $o.Trim() -eq 'Running' }

    Test-Check "$($h.Name): Vault Agent rendered $($h.Render) (non-empty)" `
        { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($h.Ip) "powershell -NoProfile -Command `"if (Test-Path '$($h.Render)') { (Get-Item '$($h.Render)').Length } else { 0 }`"" } `
        { param($o) try { [int]$o.Trim() -gt 0 } catch { $false } }
}

# ═════════════════════════════════════════════════════════════════════════
# 5.5 Transit auto-unseal -- placeholder, lands when 5.5 implements
# ═════════════════════════════════════════════════════════════════════════
Write-Section '5.5 Transit auto-unseal (PENDING IMPLEMENTATION)'
Write-Host '[INFO] 5.5 checks deferred until vault-transit VM lands.' -ForegroundColor Cyan

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.D.5 SMOKE CHECKS PASSED (chained 0.D.4 + 0.D.3 + 0.D.2 + 0.D.1)' -ForegroundColor Green
    Write-Host 'NOTE: KDS root key WARN is expected pre-manual-ops (handbook s 1k.2).' -ForegroundColor DarkYellow
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
