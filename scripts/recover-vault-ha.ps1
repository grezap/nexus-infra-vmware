#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Recover the Vault HA cluster after a build-host reboot.

.DESCRIPTION
  vault-transit is single-node Shamir-unsealed (it's the bottom of the
  auto-unseal chain for vault-1/2/3). On a build-host reboot:

    1. All VMs come back up
    2. vault-transit starts SEALED (Shamir; no auto-unseal under it)
    3. vault-1/2/3 systemd-start, try to fetch their seal key from
       transit, get 503 "Vault is sealed", exit 1
    4. systemd's default 3-retries-in-5-seconds is too aggressive and
       gives up before transit is unsealed
    5. Entire HA cluster sits in `failed` state until manual recovery

  This script automates the recovery:
    1. Submit Shamir unseal keys from `~/.nexus/vault-transit-init.json`
       to vault-transit (kept in PowerShell variables only, never echoed)
    2. `systemctl reset-failed vault && systemctl start vault` on
       vault-1/2/3
    3. Poll vault-1 until unsealed (typically 10-30s)

  Also installs (idempotently) a systemd drop-in on vault-1/2/3 that
  raises StartLimitBurst=15 + StartLimitIntervalSec=600. This gives the
  HA nodes 15 retries over 10 minutes instead of 3 in 5 seconds, so a
  future restart races more gracefully when transit takes time to come
  back. The drop-in pairs with this script -- belt + suspenders.

  Idempotent: safe to re-run. If vault-transit is already unsealed, the
  unseal calls return success no-op. If HA nodes are already up,
  reset-failed + start is a no-op.

.PARAMETER InitFile
  Path to the vault-transit init JSON (default: ~/.nexus/vault-transit-init.json).

.PARAMETER SkipDropIn
  Skip the systemd drop-in install step (use for read-only recovery).

.EXAMPLE
  pwsh -File scripts/recover-vault-ha.ps1

.NOTES
  Sister to Phase 0.D.5 (vault-transit deploy) + handbook §3.2.
  Memory anchor: feedback_vault_transit_boot_race_recovery.md
#>

[CmdletBinding()]
param(
    [string]$InitFile = "$env:USERPROFILE\.nexus\vault-transit-init.json",
    [switch]$SkipDropIn
)

$ErrorActionPreference = 'Stop'

$haIps = @('192.168.70.121', '192.168.70.122', '192.168.70.123')
$transitIp = '192.168.70.124'
$caBundle = "$env:USERPROFILE\.nexus\vault-ca-bundle.crt"

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

# --- Phase 1: read transit init (keys held in memory only, never echoed) ---
Write-Step 'Reading vault-transit-init.json'
if (-not (Test-Path $InitFile)) {
    throw "init file not found at $InitFile"
}
$transitInit = Get-Content -Raw $InitFile | ConvertFrom-Json
if (-not $transitInit.unseal_keys_b64 -or $transitInit.unseal_keys_b64.Count -lt 1) {
    throw "init file at $InitFile has no unseal_keys_b64 array"
}
$threshold = if ($transitInit.unseal_threshold) { $transitInit.unseal_threshold } else { 3 }
Write-Host "  unseal threshold: $threshold"

# --- Phase 2: unseal vault-transit ---
Write-Step 'Unsealing vault-transit'
$env:VAULT_ADDR = "https://${transitIp}:8200"
$env:VAULT_CACERT = $caBundle
# Vault CLI on Windows often can't validate the lab's CA chain even with
# VAULT_CACERT pointed at the bundle (Go's x509 vs. the cert's IP SAN-only
# subject in some lab CA chains). SKIP_VERIFY is acceptable here: we're
# the operator running locally and the trust boundary is the lab itself.
$env:VAULT_SKIP_VERIFY = 'true'

# Pre-check: is it already unsealed?
$transitStatus = & vault status -format=json 2>$null
if ($LASTEXITCODE -eq 0) {
    $st = $transitStatus | ConvertFrom-Json
    if (-not $st.sealed) {
        Write-Host "  already unsealed; skipping"
    } else {
        for ($i = 0; $i -lt $threshold; $i++) {
            $key = $transitInit.unseal_keys_b64[$i]
            & vault operator unseal $key | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "transit unseal failed at key index $i"
            }
        }
    }
} elseif ($LASTEXITCODE -eq 2) {
    # exit 2 = sealed but reachable
    for ($i = 0; $i -lt $threshold; $i++) {
        $key = $transitInit.unseal_keys_b64[$i]
        & vault operator unseal $key | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "transit unseal failed at key index $i"
        }
    }
} else {
    throw "vault-transit at $transitIp is unreachable (vault status exit=$LASTEXITCODE)"
}

$transitFinal = & vault status -format=json | ConvertFrom-Json
if ($transitFinal.sealed) {
    throw "vault-transit STILL sealed after submitting $threshold keys"
}
Write-Host "  vault-transit: sealed=$($transitFinal.sealed), initialized=$($transitFinal.initialized), version=$($transitFinal.version)" -ForegroundColor Green

# --- Phase 3: kick HA nodes ---
Write-Step 'Restarting vault.service on HA nodes'
foreach ($ip in $haIps) {
    Write-Host "  - $ip"
    & ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip 'sudo systemctl reset-failed vault 2>/dev/null ; sudo systemctl start vault'
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "    start returned $LASTEXITCODE on $ip; check journalctl manually"
    }
}

# --- Phase 4: poll for HA cluster up ---
Write-Step 'Waiting for HA cluster to come online'
$env:VAULT_ADDR = "https://$($haIps[0]):8200"
$success = $false
for ($attempt = 1; $attempt -le 18; $attempt++) {
    Start-Sleep -Seconds 5
    $haStatus = & vault status -format=json 2>$null
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) {
        try {
            $obj = $haStatus | ConvertFrom-Json
            if ($obj -and -not $obj.sealed) {
                $role = if ($obj.is_self -or -not $obj.standby) { 'active' } else { 'standby' }
                Write-Host "  vault-1: sealed=false, role=$role, cluster_name=$($obj.cluster_name)" -ForegroundColor Green
                $success = $true
                break
            }
        } catch { }
    }
    Write-Host "  attempt $attempt/18: still waiting..."
}
if (-not $success) {
    throw 'HA cluster did not unseal within 90 seconds; investigate journalctl on vault-1/2/3'
}

# --- Phase 5: install systemd drop-in (idempotent, prevents the next reboot from repeating this dance) ---
if (-not $SkipDropIn) {
    Write-Step 'Installing systemd drop-in for restart tolerance'
    $dropin = @"
[Unit]
# Tolerate a vault-transit boot race after a host reboot. vault-transit
# is Shamir-only (no auto-unseal beneath it), so the HA nodes can fail
# their seal key fetch if they boot before transit is manually unsealed.
# Default systemd 3-retries-in-5-seconds is too tight: it gives up
# before any operator can run the recovery script. 15 retries over 10
# minutes (RestartSec=10 * 15 = 150s active wait; window covers the
# typical operator response time + the build-host recover script).
StartLimitBurst=15
StartLimitIntervalSec=600

[Service]
RestartSec=10
"@
    $dropinB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dropin))
    foreach ($ip in $haIps) {
        Write-Host "  - $ip"
        $remoteCmd = "sudo mkdir -p /etc/systemd/system/vault.service.d && echo $dropinB64 | base64 -d | sudo tee /etc/systemd/system/vault.service.d/10-restart-tolerance.conf >/dev/null && sudo systemctl daemon-reload"
        & ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip $remoteCmd
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    drop-in install returned $LASTEXITCODE on $ip"
        }
    }
}

Write-Host ''
Write-Host '[ok] Vault HA recovered.' -ForegroundColor Green
