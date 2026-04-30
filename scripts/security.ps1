#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the security env (Vault cluster) -- pwsh-native
  equivalent of the bash-shaped Makefile targets.

.DESCRIPTION
  Mirrors scripts/foundation.ps1 shape (per memory/feedback_build_host_pwsh_native.md
  -- GNU make is not installed on the build host; pwsh wrappers are canonical).
  Provides apply/destroy/smoke/cycle/plan/validate verbs against
  terraform/envs/security/ + delegates smoke to scripts/smoke-0.D.1.ps1.

  Pre-flight dependency: nexus-gateway must have the Vault dnsmasq dhcp-host
  reservations active (foundation env's role-overlay-gateway-vault-reservations.tf,
  toggled via -Vars enable_vault_dhcp_reservations=true on foundation apply).
  This wrapper does NOT check or apply those reservations -- foundation env
  ownership stays separate. The handbook s 2 documents the order.

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/security
  destroy  -- terraform destroy -auto-approve
  smoke    -- run the active phase smoke gate (default 0.D.2; chains 0.D.1)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Phase
  Which smoke phase to run. '0.D.2' (default) runs the full PKI smoke gate
  which chains 0.D.1 first. '0.D.1' runs the cluster-only gate (useful for
  iterating with -Vars enable_vault_pki=false).

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags. Applies
  to apply/plan/cycle.

.PARAMETER SmokeArgs
  Hashtable forwarded to the smoke script (e.g. -SmokeArgs @{KvMountPath='custom-nexus'}).

.EXAMPLE
  pwsh -File scripts\security.ps1 cycle

.EXAMPLE
  pwsh -File scripts\security.ps1 apply -Vars enable_vault_init=false

.EXAMPLE
  # iterate on the cluster bring-up alone, skip PKI
  pwsh -File scripts\security.ps1 apply -Vars enable_vault_pki=false
  pwsh -File scripts\security.ps1 smoke -Phase 0.D.1

.NOTES
  See scripts/smoke-0.D.1.ps1 (cluster-only gate) and scripts/smoke-0.D.2.ps1
  (PKI gate, chains 0.D.1) for the underlying check definitions.
  See scripts/foundation.ps1 for the same shape applied to envs/foundation/.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [ValidateSet('0.D.1', '0.D.2')]
    [string]$Phase = '0.D.2',

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\security'
$smokePath = Join-Path $repoRoot ("scripts\smoke-{0}.ps1" -f $Phase)

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) {
            throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
}

function Get-VarFlags {
    $flags = @()
    foreach ($v in $Vars) { $flags += @('-var', $v) }
    return $flags
}

function Invoke-Apply {
    Write-Step 'terraform apply -auto-approve'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step "pwsh -File $(Split-Path -Leaf $smokePath) (phase $Phase)"
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found for phase $Phase`: $smokePath"
    }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "smoke gate failed (exit $LASTEXITCODE)"
    }
}

function Invoke-Plan {
    Write-Step 'terraform plan'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate'
    Invoke-Terraform @('validate')
}

# ─── Dispatch ─────────────────────────────────────────────────────────────
switch ($Verb) {
    'apply'    { Invoke-Apply }
    'destroy'  { Invoke-Destroy }
    'smoke'    { Invoke-Smoke }
    'plan'     { Invoke-Plan }
    'validate' { Invoke-Validate }
    'cycle' {
        Invoke-Destroy
        Invoke-Apply
        Invoke-Smoke
    }
}

Write-Host ''
Write-Host "security $Verb complete" -ForegroundColor Green
