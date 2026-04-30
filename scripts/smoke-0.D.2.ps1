#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.D.2 smoke gate: verify the Vault PKI overlay (root + intermediate
  CAs, vault-server role, per-node listener cert reissuance, build-host CA
  bundle distribution, legacy trust cleanup) on top of the 0.D.1 cluster.

.DESCRIPTION
  Strict superset of scripts/smoke-0.D.1.ps1 -- chains the 0.D.1 gate first
  (so a sick cluster fails fast), then layers the PKI checks. Run AFTER
  `pwsh -File scripts\security.ps1 apply` returns clean.

  Exits 0 on all-green, 1 if any check failed.

.PARAMETER Vault1Ip
  vault-1 IP. Default 192.168.70.121 (canonical per vms.yaml).

.PARAMETER Vault2Ip
  vault-2 IP. Default 192.168.70.122.

.PARAMETER Vault3Ip
  vault-3 IP. Default 192.168.70.123.

.PARAMETER KvMountPath
  KV-v2 mount path. Default 'nexus' (per MASTER-PLAN.md s 0.D goal).

.PARAMETER UserpassUser
  userpass username to verify. Default 'nexusadmin'.

.PARAMETER ApproleName
  AppRole role name to verify. Default 'nexus-bootstrap'.

.PARAMETER InitKeysFile
  Path to vault-init.json on build host. Default $HOME/.nexus/vault-init.json.

.PARAMETER CaBundlePath
  Path to root CA bundle on build host (written by the distribute overlay).
  Default $HOME/.nexus/vault-ca-bundle.crt.

.PARAMETER IntermediateCommonName
  Expected CN of the intermediate CA. Default 'NexusPlatform Intermediate CA'.

.PARAMETER RootCommonName
  Expected CN of the root CA. Default 'NexusPlatform Root CA'.

.PARAMETER RoleName
  Expected PKI role name. Default 'vault-server'.

.PARAMETER MinLeafTtlDays
  Minimum days remaining on each leaf cert (1y issuance ≈ 365d, lower bound 300d). Default 300.

.PARAMETER SkipPhase0D1
  If $true, skips the chained 0.D.1 gate and runs only the 0.D.2 PKI checks.
  Useful when iterating on PKI overlays alone. Default $false.

.NOTES
  See also:
    docs/handbook.md s 1h                      (Phase 0.D.2 reference)
    memory/feedback_lab_host_reachability.md   (the SSH+8200 invariant carried forward)
#>

[CmdletBinding()]
param(
    [string]$Vault1Ip               = '192.168.70.121',
    [string]$Vault2Ip               = '192.168.70.122',
    [string]$Vault3Ip               = '192.168.70.123',
    [string]$KvMountPath            = 'nexus',
    [string]$UserpassUser           = 'nexusadmin',
    [string]$ApproleName            = 'nexus-bootstrap',
    [string]$InitKeysFile           = $null,
    [string]$CaBundlePath           = $null,
    [string]$IntermediateCommonName = 'NexusPlatform Intermediate CA',
    [string]$RootCommonName         = 'NexusPlatform Root CA',
    [string]$RoleName               = 'vault-server',
    [int]   $MinLeafTtlDays         = 300,
    [switch]$SkipPhase0D1
)

if (-not $InitKeysFile) {
    $InitKeysFile = Join-Path $env:USERPROFILE '.nexus/vault-init.json'
}
if (-not $CaBundlePath) {
    $CaBundlePath = Join-Path $env:USERPROFILE '.nexus/vault-ca-bundle.crt'
}

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

# ─── Phase 0.D.1 chained gate (strict prerequisite) ──────────────────────
if (-not $SkipPhase0D1) {
    Write-Section 'Phase 0.D.1 chained smoke gate'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $smoke01  = Join-Path $repoRoot 'scripts\smoke-0.D.1.ps1'
    if (-not (Test-Path $smoke01)) {
        Write-Host "[FAIL] 0.D.1 smoke script not found at $smoke01" -ForegroundColor Red
        $script:failures += '0.D.1 smoke script missing'
    } else {
        & pwsh -NoProfile -File $smoke01 `
            -Vault1Ip $Vault1Ip -Vault2Ip $Vault2Ip -Vault3Ip $Vault3Ip `
            -KvMountPath $KvMountPath -UserpassUser $UserpassUser `
            -ApproleName $ApproleName -InitKeysFile $InitKeysFile
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[FAIL] 0.D.1 chained smoke gate (exit=$LASTEXITCODE)" -ForegroundColor Red
            $script:failures += '0.D.1 chained smoke gate'
            Write-Host ''
            Write-Host "0.D.1 gate failed; halting before 0.D.2 PKI checks" -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host ''
Write-Host "Phase 0.D.2 smoke gate: PKI overlay" -ForegroundColor White

# Need the root token for PKI reads
$rootToken = $null
if (Test-Path $InitKeysFile) {
    try { $rootToken = (Get-Content $InitKeysFile | ConvertFrom-Json).root_token } catch { }
}
if (-not $rootToken) {
    Write-Host "[FAIL] $InitKeysFile not readable -- cannot run PKI checks without root token" -ForegroundColor Red
    $script:failures += "init keys file not readable"
    exit 1
}

# ─── 1. PKI engines mounted ───────────────────────────────────────────────
Write-Section 'PKI engines mounted'
Test-Check 'pki/ secrets engine mounted' `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'secrets list -format=json' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            $m = $j.PSObject.Properties | Where-Object { $_.Name -eq 'pki/' }
            $m -and $m.Value.type -eq 'pki'
        } catch { $false }
    }

Test-Check 'pki_int/ secrets engine mounted' `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'secrets list -format=json' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            $m = $j.PSObject.Properties | Where-Object { $_.Name -eq 'pki_int/' }
            $m -and $m.Value.type -eq 'pki'
        } catch { $false }
    }

# ─── 2. Root + intermediate CA exist with expected CNs ────────────────────
Write-Section 'CA hierarchy'
Test-Check "root CA exists with CN '$RootCommonName'" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json pki/cert/ca' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            $cert = $j.data.certificate
            if (-not $cert) { return $false }
            # Send cert through openssl on vault-1 to extract subject
            $subjRaw = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip "echo '$cert' | openssl x509 -noout -subject"
            $subjRaw -match [regex]::Escape($RootCommonName)
        } catch { $false }
    }

Test-Check "intermediate CA exists with CN '$IntermediateCommonName'" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json pki_int/cert/ca' -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            $cert = $j.data.certificate
            if (-not $cert) { return $false }
            $subjRaw = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip "echo '$cert' | openssl x509 -noout -subject"
            $subjRaw -match [regex]::Escape($IntermediateCommonName)
        } catch { $false }
    }

Test-Check 'intermediate CA is signed by the root CA (chain validates)' `
    {
        # Pull both certs and run openssl verify on vault-1
        $rootCertRaw = (Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json pki/cert/ca' -Token $rootToken | ConvertFrom-Json).data.certificate
        $intCertRaw  = (Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json pki_int/cert/ca' -Token $rootToken | ConvertFrom-Json).data.certificate
        # Stage on vault-1 + run openssl verify
        $bash = "set -e; ROOT=`$(mktemp); INT=`$(mktemp); echo '$rootCertRaw' > `$ROOT; echo '$intCertRaw' > `$INT; openssl verify -CAfile `$ROOT `$INT; rm -f `$ROOT `$INT"
        ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Vault1Ip "$bash"
    } `
    { param($o) $o.Trim() -match ': OK\s*$' }

# ─── 3. PKI role configured ───────────────────────────────────────────────
Write-Section 'PKI role'
Test-Check "pki_int/roles/$RoleName exists" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "read -format=json pki_int/roles/$RoleName" -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            $j.data -and $j.data.allowed_domains
        } catch { $false }
    }

Test-Check "pki_int/roles/$RoleName has allow_ip_sans=true" `
    { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "read -format=json pki_int/roles/$RoleName" -Token $rootToken } `
    {
        param($o)
        try {
            $j = $o | ConvertFrom-Json
            $j.data.allow_ip_sans -eq $true
        } catch { $false }
    }

# ─── 4. Per-node listener cert is PKI-issued + SAN-correct + fresh ────────
Write-Section 'Per-node listener cert (PKI-issued, SAN, TTL)'
foreach ($node in @(
        @{ Name = 'vault-1'; Ip = $Vault1Ip; Vmnet10 = '192.168.10.121' },
        @{ Name = 'vault-2'; Ip = $Vault2Ip; Vmnet10 = '192.168.10.122' },
        @{ Name = 'vault-3'; Ip = $Vault3Ip; Vmnet10 = '192.168.10.123' }
    )) {
    $nodeRef = $node

    Test-Check "$($nodeRef.Name): listener cert is signed by '$IntermediateCommonName'" `
        {
            ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($nodeRef.Ip) `
                "echo Q | openssl s_client -connect 127.0.0.1:8200 -servername $($nodeRef.Name).nexus.lab 2>/dev/null | openssl x509 -noout -issuer"
        } `
        { param($o) $o -match [regex]::Escape($IntermediateCommonName) }

    Test-Check "$($nodeRef.Name): listener cert SAN covers $($nodeRef.Ip), $($nodeRef.Vmnet10), 127.0.0.1, $($nodeRef.Name).nexus.lab" `
        {
            ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($nodeRef.Ip) `
                "echo Q | openssl s_client -connect 127.0.0.1:8200 -servername $($nodeRef.Name).nexus.lab 2>/dev/null | openssl x509 -noout -ext subjectAltName"
        } `
        {
            param($o)
            ($o -match [regex]::Escape($nodeRef.Ip)) -and `
            ($o -match [regex]::Escape($nodeRef.Vmnet10)) -and `
            ($o -match '127\.0\.0\.1') -and `
            ($o -match [regex]::Escape("$($nodeRef.Name).nexus.lab"))
        }

    # Use openssl x509 -checkend SECONDS on the remote node to avoid culture-sensitive
    # date parsing on the Windows build host (en-US format "Apr 30 20:34:50 2027 GMT"
    # may not parse cleanly under non-en cultures). Returns 0 if cert is valid for
    # at least N more seconds, non-zero otherwise. We echo a stable marker token
    # for the predicate to grep, robust against any stderr noise.
    $minSecs = $MinLeafTtlDays * 86400
    Test-Check "$($nodeRef.Name): listener cert >$MinLeafTtlDays days remaining" `
        {
            ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($nodeRef.Ip) `
                "echo Q | openssl s_client -connect 127.0.0.1:8200 -servername $($nodeRef.Name).nexus.lab 2>/dev/null | openssl x509 -checkend $minSecs >/dev/null && echo TTL_OK || echo TTL_TOO_SHORT"
        } `
        { param($o) $o -match '\bTTL_OK\b' }
}

# ─── 5. Build-host CA bundle present + matches PKI root ───────────────────
Write-Section 'Build-host CA bundle distribution'
Test-Check "CA bundle exists at $CaBundlePath" `
    { Test-Path $CaBundlePath } `
    { param($o) $o.Trim() -eq 'True' }

Test-Check 'CA bundle content matches Vault pki/cert/ca (hash compare)' `
    {
        $bundleRaw = ((Get-Content $CaBundlePath -Raw) -replace "`r`n", "`n").Trim()
        $vaultRaw  = ((Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'read -format=json pki/cert/ca' -Token $rootToken | ConvertFrom-Json).data.certificate -replace "`r`n", "`n").Trim()
        if ($bundleRaw -eq $vaultRaw) { 'MATCH' } else { "MISMATCH (bundle=$($bundleRaw.Length) bytes, vault=$($vaultRaw.Length) bytes)" }
    } `
    { param($o) $o.Trim() -eq 'MATCH' }

# ─── 6. Build-host vault status works with VAULT_CACERT (no skip-verify) ──
Write-Section 'Build-host TLS validation via VAULT_CACERT'
foreach ($node in @(
        @{ Name = 'vault-1'; Ip = $Vault1Ip },
        @{ Name = 'vault-2'; Ip = $Vault2Ip },
        @{ Name = 'vault-3'; Ip = $Vault3Ip }
    )) {
    $nodeRef = $node
    # Use .NET TLS handshake against the bundle to avoid a hard dependency on a vault.exe install
    Test-Check "$($nodeRef.Name): TLS handshake validates against build-host CA bundle (no skip-verify)" `
        {
            try {
                $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CaBundlePath
                $caThumb = $caCert.Thumbprint
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect($nodeRef.Ip, 8200)
                $stream = $tcp.GetStream()
                # Custom validation: build a chain rooted in our supplied CA bundle.
                # The TLS handshake's $chain parameter contains the certs the server
                # supplied (leaf + any intermediates). We move those intermediates
                # into ExtraStore so the custom builder can construct the full path
                # leaf -> intermediate -> root, where the root is our trusted bundle.
                $callback = {
                    param($sender, $cert, $chain, $errors)
                    [System.Security.Cryptography.X509Certificates.X509Certificate2]$leaf = $cert
                    $custom = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                    $custom.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                    $custom.ChainPolicy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
                    $custom.ChainPolicy.CustomTrustStore.Add($caCert) | Out-Null
                    if ($chain -and $chain.ChainElements) {
                        foreach ($el in $chain.ChainElements) {
                            $thumb = $el.Certificate.Thumbprint
                            if ($thumb -ne $leaf.Thumbprint -and $thumb -ne $caThumb) {
                                $custom.ChainPolicy.ExtraStore.Add($el.Certificate) | Out-Null
                            }
                        }
                    }
                    return $custom.Build($leaf)
                }
                $ssl = New-Object System.Net.Security.SslStream($stream, $false, $callback)
                $ssl.AuthenticateAsClient("$($nodeRef.Name).nexus.lab")
                $remote = $ssl.RemoteCertificate
                $ssl.Close(); $tcp.Close()
                if ($remote) { 'HANDSHAKE_OK' } else { 'NO_REMOTE_CERT' }
            } catch {
                "HANDSHAKE_FAIL: $($_.Exception.Message)"
            }
        } `
        { param($o) $o.Trim() -eq 'HANDSHAKE_OK' }
}

# ─── 7. Legacy trust anchor cleaned up on followers ───────────────────────
Write-Section 'Legacy 0.D.1 trust shuffle cleaned up'
foreach ($node in @(
        @{ Name = 'vault-2'; Ip = $Vault2Ip },
        @{ Name = 'vault-3'; Ip = $Vault3Ip }
    )) {
    $nodeRef = $node
    # NB: sudo on the node emits "unable to resolve host vault-N: Temporary failure
    # in name resolution" to stderr because vault-firstboot.sh sets the hostname via
    # hostnamectl but doesn't add a 127.0.1.1 entry to /etc/hosts. The warning is
    # harmless but lands in the SSH output; predicates use -match on a marker token
    # instead of strict equality so they tolerate the noise. Root-cause fix tracked
    # for a vault-firstboot.sh patch (template rebuild).
    Test-Check "$($nodeRef.Name): /usr/local/share/ca-certificates/vault-leader.crt absent (0.D.1 hack retired)" `
        {
            ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($nodeRef.Ip) `
                "if sudo test -f /usr/local/share/ca-certificates/vault-leader.crt 2>/dev/null; then echo LEGACY_PRESENT; else echo LEGACY_ABSENT; fi"
        } `
        { param($o) $o -match '\bLEGACY_ABSENT\b' -and $o -notmatch '\bLEGACY_PRESENT\b' }
}

# ─── 8. Shared PKI root installed on every node ───────────────────────────
Write-Section 'Shared PKI root in every Vault node trust store'
foreach ($node in @(
        @{ Name = 'vault-1'; Ip = $Vault1Ip },
        @{ Name = 'vault-2'; Ip = $Vault2Ip },
        @{ Name = 'vault-3'; Ip = $Vault3Ip }
    )) {
    $nodeRef = $node
    Test-Check "$($nodeRef.Name): /usr/local/share/ca-certificates/nexus-vault-pki-root.crt present" `
        {
            ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($nodeRef.Ip) `
                "if sudo test -f /usr/local/share/ca-certificates/nexus-vault-pki-root.crt 2>/dev/null; then echo ROOT_PRESENT; else echo ROOT_ABSENT; fi"
        } `
        { param($o) $o -match '\bROOT_PRESENT\b' -and $o -notmatch '\bROOT_ABSENT\b' }
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.D.2 SMOKE CHECKS PASSED (chained 0.D.1 + PKI overlay)' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
