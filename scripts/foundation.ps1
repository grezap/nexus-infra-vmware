#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the foundation env -- pwsh-native equivalent of the
  bash-shaped Makefile targets.

.DESCRIPTION
  The build host runs Windows pwsh with no GNU make installed (see
  memory/feedback_build_host_pwsh_native.md). This wrapper provides
  apply/destroy/smoke/cycle/plan/validate verbs against
  terraform/envs/foundation so the canonical operator path on Windows is
  `pwsh -File scripts\foundation.ps1 <verb>`. The Makefile equivalents
  remain functional in Linux/WSL/CI contexts.

  smoke delegates to scripts/smoke-0.C.4.ps1; cycle = destroy -> apply -> smoke
  chained, halting on first failure.

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/foundation
  destroy  -- terraform destroy -auto-approve
  smoke    -- run scripts/smoke-0.C.4.ps1 (24-check Phase 0.C.4 smoke gate)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags. Applies to
  the apply, plan, and cycle verbs (cycle's apply step). Ignored on others.

.PARAMETER SmokeArgs
  Hashtable forwarded to smoke-0.C.4.ps1 (e.g. -SmokeArgs @{Domain='nexus.lab'}).
  Useful when a -Vars override would change a smoke-checked value.

.EXAMPLE
  # Default cycle: destroy -> apply -> smoke
  pwsh -File scripts\foundation.ps1 cycle

.EXAMPLE
  # Apply with var override
  pwsh -File scripts\foundation.ps1 apply -Vars enable_dc_password_policy=false

.EXAMPLE
  # Apply + smoke with a non-default password policy
  pwsh -File scripts\foundation.ps1 apply -Vars dc_password_min_length=14
  pwsh -File scripts\foundation.ps1 smoke -SmokeArgs @{MinPasswordLength=14}

.NOTES
  Reproducibility canon: the cycle verb mirrors the manual flow that proved
  Phase 0.C.3 + 0.C.4 reproducibility (cold destroy -> cold apply ->
  zero-failure smoke gate). ~17-18 min wall-clock on the current build host.

  See also:
    scripts/smoke-0.C.4.ps1                          (the smoke gate)
    docs/handbook.md s 1c-1f                         (per-phase context)
    memory/feedback_build_host_pwsh_native.md        (why pwsh-native)
    memory/feedback_lab_host_reachability.md         (why smoke gates SSH/22+RDP/3389)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

# Resolve repo root from script location -- works whether invoked from repo
# root, scripts/, or any other cwd.
$repoRoot   = Split-Path -Parent $PSScriptRoot
$envDir     = Join-Path $repoRoot 'terraform\envs\foundation'
$smokePath  = Join-Path $repoRoot 'scripts\smoke-0.C.4.ps1'

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
    # Returns a flat array of "-var", "key=value", "-var", "key=value", ...
    #
    # Accepts both styles:
    #   -Vars 'enable_x=true','enable_y=true'           (PS array syntax; works in interactive PS)
    #   -Vars 'enable_x=true,enable_y=true'             (comma-separated single string; needed when invoked via pwsh -File)
    #
    # The pwsh -File entrypoint does NOT auto-tokenize commas, so a single
    # comma-joined token arrives as one element and must be split here. Split
    # on `,` and trim each piece. This breaks down for var values that
    # legitimately contain a comma; in that case, pass the var as its own
    # array element (`-Vars 'a=hello,world','b=2'`).
    $flags = @()
    foreach ($v in $Vars) {
        foreach ($piece in ($v -split ',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $flags += @('-var', $trimmed) }
        }
    }
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
    Write-Step "pwsh -File $(Split-Path -Leaf $smokePath)"
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found: $smokePath"
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
Write-Host "foundation $Verb complete" -ForegroundColor Green
