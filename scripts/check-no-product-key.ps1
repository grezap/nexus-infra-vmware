#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Pre-commit guard: refuses staged changes containing a Microsoft product key.

.DESCRIPTION
  Pattern:  XXXXX-XXXXX-XXXXX-XXXXX-XXXXX  (5 groups of 5 alphanumerics).
  Invoked by git pre-commit hook and by CI (.github/workflows/packer-validate.yml).
  See docs/licensing.md and ADR-0144 for the full defense-in-depth story.

  Exits non-zero on match so the commit / CI job fails loudly.

.NOTES
  Literal placeholders in docs, *.tpl templates, this script itself, and
  .gitleaks.toml are excluded to avoid false positives.
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Paths
)

$ErrorActionPreference = 'Stop'

$keyPattern = '\b[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b'

$excludePathPatterns = @(
  '\.tpl$'
  'docs/.*licensing\.md$'
  '\.gitleaks\.toml$'
  'scripts/check-no-product-key\.ps1$'
  'CHANGELOG\.md$'
)

$placeholderAllow = @(
  'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX'
  '00000-00000-00000-00000-00000'
)

if (-not $Paths -or $Paths.Count -eq 0) {
  # Default: scan staged additions
  $staged = git diff --cached --name-only --diff-filter=AM 2>$null
  if ($LASTEXITCODE -ne 0) { $staged = @() }
  $Paths = $staged | Where-Object { $_ -and (Test-Path $_) }
}

$violations = @()
foreach ($p in $Paths) {
  $skip = $false
  foreach ($x in $excludePathPatterns) { if ($p -match $x) { $skip = $true; break } }
  if ($skip) { continue }

  try { $content = Get-Content -LiteralPath $p -Raw -ErrorAction Stop } catch { continue }
  if (-not $content) { continue }

  $matchResults = [regex]::Matches($content, $keyPattern)
  foreach ($m in $matchResults) {
    if ($placeholderAllow -contains $m.Value) { continue }
    $violations += [PSCustomObject]@{ File = $p; Match = $m.Value }
  }
}

if ($violations.Count -gt 0) {
  Write-Error @"
[check-no-product-key] Refusing to commit: Microsoft product key pattern detected.

$($violations | ForEach-Object { "  $($_.File)  ->  $($_.Match)" } | Out-String)

Product keys must NEVER enter git. See docs/licensing.md for the Vault-based
custody path and the Autounattend.xml.tpl templating pattern.
"@
  exit 1
}

Write-Host "[check-no-product-key] OK ($($Paths.Count) path(s) scanned, 0 violations)."
exit 0
