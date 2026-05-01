#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.D.1 smoke gate: verify the 3-node Vault Raft cluster + KV-v2 +
  auth methods + build-host reachability invariant.

.DESCRIPTION
  Run AFTER `pwsh -File scripts\security.ps1 apply` returns clean. Validates
  all four layers landed by the cluster bring-up overlay (cluster up, leader
  elected, KV-v2 mounted, auth methods enabled, smoke secret readable),
  plus build-host reachability per memory/feedback_lab_host_reachability.md
  (every Vault node SSH/22 + 8200 reachable from the build host).

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

.NOTES
  Assumes handbook s 0.4 SSH client setup is done -- bare `ssh nexusadmin@<ip>`
  works zero-touch via ~/.ssh/config + ssh-agent. Vault CLI commands run
  via SSH on the nodes themselves; the build host doesn't need the Vault
  binary installed.

  See also:
    docs/handbook.md s 2                 (Phase 0.D.1 reference)
    memory/feedback_lab_host_reachability.md  (the SSH+8200 invariant)
#>

[CmdletBinding()]
param(
    [string]$Vault1Ip      = '192.168.70.121',
    [string]$Vault2Ip      = '192.168.70.122',
    [string]$Vault3Ip      = '192.168.70.123',
    [string]$KvMountPath   = 'nexus',
    [string]$UserpassUser  = 'nexusadmin',
    [string]$ApproleName   = 'nexus-bootstrap',
    [string]$InitKeysFile  = $null
)

if (-not $InitKeysFile) {
    $InitKeysFile = Join-Path $env:USERPROFILE '.nexus/vault-init.json'
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

# Wrapper for SSH-to-Vault-node + Vault CLI (with VAULT_SKIP_VERIFY for self-signed bootstrap)
function Invoke-VaultCli {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$VaultCmd,
        [string]$Token = ''
    )
    $tokenPart = if ($Token) { "VAULT_TOKEN='$Token' " } else { '' }
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Ip "${tokenPart}VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault $VaultCmd"
}

Write-Host "Phase 0.D.1 smoke gate: vault-1=$Vault1Ip, vault-2=$Vault2Ip, vault-3=$Vault3Ip, kv=$KvMountPath/" -ForegroundColor White

# ─── 1. Build-host reachability invariant (FIRST -- moot if this fails)
Write-Section 'Build-host reachability (SSH/22 + Vault API/8200)'
foreach ($node in @(
        @{ Name = 'vault-1'; Ip = $Vault1Ip },
        @{ Name = 'vault-2'; Ip = $Vault2Ip },
        @{ Name = 'vault-3'; Ip = $Vault3Ip }
    )) {
    $nodeRef = $node
    foreach ($port in @(22, 8200)) {
        $portRef = $port
        Test-Check "$($nodeRef.Name) $($nodeRef.Ip):$portRef reachable" `
            { Test-NetConnection -ComputerName $nodeRef.Ip -Port $portRef -InformationLevel Quiet -WarningAction SilentlyContinue } `
            { param($o) $o.Trim() -eq 'True' }
    }
}

# ─── 2. Cluster topology + canonical IP assertions
Write-Section 'Canonical IPs (per vms.yaml)'
foreach ($node in @(
        @{ Name = 'vault-1'; Ip = $Vault1Ip; Vmnet10 = '192.168.10.121' },
        @{ Name = 'vault-2'; Ip = $Vault2Ip; Vmnet10 = '192.168.10.122' },
        @{ Name = 'vault-3'; Ip = $Vault3Ip; Vmnet10 = '192.168.10.123' }
    )) {
    $nodeRef = $node
    Test-Check "$($nodeRef.Name): VMnet10 IP $($nodeRef.Vmnet10) configured on nic1" `
        { ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($nodeRef.Ip) "ip -4 -o addr show nic1 2>/dev/null | awk '{print `$4}' | cut -d/ -f1" } `
        { param($o) $o.Trim() -eq $nodeRef.Vmnet10 }
}

# ─── 3. vault.service running + initialized + unsealed on all 3 nodes
Write-Section 'vault.service health'
foreach ($node in @(
        @{ Name = 'vault-1'; Ip = $Vault1Ip },
        @{ Name = 'vault-2'; Ip = $Vault2Ip },
        @{ Name = 'vault-3'; Ip = $Vault3Ip }
    )) {
    $nodeRef = $node
    Test-Check "$($nodeRef.Name): vault.service active" `
        { ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$($nodeRef.Ip) "systemctl is-active vault.service" } `
        { param($o) $o.Trim() -eq 'active' }

    Test-Check "$($nodeRef.Name): initialized + unsealed" `
        { Invoke-VaultCli -Ip $nodeRef.Ip -VaultCmd 'status -format=json' } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                ($j.initialized -eq $true) -and ($j.sealed -eq $false)
            } catch { $false }
        }
}

# ─── 4. Cluster has exactly 3 raft peers, 1 leader
Write-Section 'Raft cluster topology'
$rootToken = $null
if (Test-Path $InitKeysFile) {
    try { $rootToken = (Get-Content $InitKeysFile | ConvertFrom-Json).root_token } catch { }
}
if (-not $rootToken) {
    Write-Host "[SKIP] $InitKeysFile not readable -- skipping cluster checks that need root token" -ForegroundColor Yellow
    $script:failures += "init keys file not found at $InitKeysFile"
} else {
    $peersRaw = Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'operator raft list-peers -format=json' -Token $rootToken
    $peersJson = $null
    try { $peersJson = $peersRaw | ConvertFrom-Json } catch { }

    Test-Check 'raft list-peers: exactly 3 servers' `
        { $peersJson | ConvertTo-Json -Depth 8 } `
        { param($o) $peersJson -and $peersJson.data.config.servers.Count -eq 3 }

    Test-Check 'raft list-peers: exactly 1 leader' `
        { $peersJson | ConvertTo-Json -Depth 8 } `
        { param($o) $peersJson -and ($peersJson.data.config.servers | Where-Object { $_.leader }).Count -eq 1 }

    # Don't pin "vault-1 must be leader" -- Raft elects whichever node currently
    # holds quorum, and after any restart / partition / recovery cycle ANY of
    # vault-1/2/3 can be the leader (by design). What we actually want to
    # verify is "the elected leader is one of our 3 known nodes," which
    # combined with "exactly 3 servers" + "exactly 1 leader" above is
    # sufficient. The earlier "vault-1 must be leader" check fired during
    # 0.D.3 close-out recovery when vault-3 was elected after the
    # rename-nic1 + restart-vault dance, even though the cluster was
    # perfectly healthy.
    Test-Check 'raft list-peers: leader is one of vault-1/2/3' `
        { $peersJson | ConvertTo-Json -Depth 8 } `
    { param($o) $peersJson -and (($peersJson.data.config.servers | Where-Object { $_.leader -and ($_.node_id -in @('vault-1', 'vault-2', 'vault-3')) }).Count -eq 1) }

    # ─── 5. KV-v2 + auth methods + smoke secret
    Write-Section 'KV-v2 + auth methods + smoke secret'

    Test-Check "KV-v2 mounted at $KvMountPath/" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'secrets list -format=json' -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $mount = $j.PSObject.Properties | Where-Object { $_.Name -eq "$KvMountPath/" }
                $mount -and $mount.Value.type -eq 'kv' -and $mount.Value.options.version -eq '2'
            } catch { $false }
        }

    Test-Check 'userpass auth enabled' `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'auth list -format=json' -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                ($j.PSObject.Properties | Where-Object { $_.Name -eq 'userpass/' }) -ne $null
            } catch { $false }
        }

    Test-Check "userpass user '$UserpassUser' exists" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "read auth/userpass/users/$UserpassUser -format=json" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data -ne $null
            } catch { $false }
        }

    Test-Check 'approle auth enabled' `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd 'auth list -format=json' -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                ($j.PSObject.Properties | Where-Object { $_.Name -eq 'approle/' }) -ne $null
            } catch { $false }
        }

    Test-Check "AppRole '$ApproleName' exists" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "read auth/approle/role/$ApproleName -format=json" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data -ne $null
            } catch { $false }
        }

    Test-Check "smoke secret readable at $KvMountPath/smoke/canary" `
        { Invoke-VaultCli -Ip $Vault1Ip -VaultCmd "kv get -format=json $KvMountPath/smoke/canary" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data.data.value -eq 'ok'
            } catch { $false }
        }

    # ─── 6. Cross-node consistency: smoke secret readable from follower too
    Write-Section 'Cross-node read consistency'
    Test-Check "smoke secret readable from vault-2 (follower)" `
        { Invoke-VaultCli -Ip $Vault2Ip -VaultCmd "kv get -format=json $KvMountPath/smoke/canary" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data.data.value -eq 'ok'
            } catch { $false }
        }

    Test-Check "smoke secret readable from vault-3 (follower)" `
        { Invoke-VaultCli -Ip $Vault3Ip -VaultCmd "kv get -format=json $KvMountPath/smoke/canary" -Token $rootToken } `
        {
            param($o)
            try {
                $j = $o | ConvertFrom-Json
                $j.data.data.value -eq 'ok'
            } catch { $false }
        }
}

# ─── Summary
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL SMOKE CHECKS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
