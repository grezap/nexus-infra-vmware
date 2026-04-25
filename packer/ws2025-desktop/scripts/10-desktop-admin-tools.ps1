# 10-desktop-admin-tools.ps1 -- Desktop Experience delta over ws2025-core
#
# Installs the admin tooling that justifies Desktop Experience over Core for
# the dc-nexus / admin-jumpbox roles (Phase 0.B.5 exit gate). Everything here
# is GUI-bearing (RSAT MMC snap-ins, GPMC, DNS Manager) so it does not belong
# in the shared baseline that ws2025-core consumes.
#
# Features installed:
#   - RSAT-AD-Tools             AD Users & Computers, AD Sites & Services, etc.
#   - RSAT-DNS-Server           DNS Manager (for the future dc-nexus role)
#   - RSAT-DHCP                 DHCP Manager
#   - GPMC                      Group Policy Management Console
#
# The actual DC promotion (Install-ADDSForest / Install-ADDSDomainController)
# does *not* happen here -- this template stays generic. The dc-nexus role
# overlay (later phase) handles promotion against a clone of this template.
#
# Edge is shipped in-box on Desktop Experience SKUs since WS2022; no install
# step needed. Same for built-in productivity (Notepad, calc, MMC, etc.).

$ErrorActionPreference = 'Stop'

Write-Host "=== 10-desktop-admin-tools ==="

$features = @(
    'RSAT-AD-Tools',
    'RSAT-DNS-Server',
    'RSAT-DHCP',
    'GPMC'
)

foreach ($feat in $features) {
    $state = (Get-WindowsFeature -Name $feat -ErrorAction SilentlyContinue).InstallState
    if ($state -eq 'Installed') {
        Write-Host "  $feat already installed -- skipping"
        continue
    }
    Write-Host "Installing $feat ..."
    $r = Install-WindowsFeature -Name $feat -IncludeManagementTools
    if (-not $r.Success) {
        throw "Install-WindowsFeature $feat failed: $($r | Out-String)"
    }
    if ($r.RestartNeeded -eq 'Yes') {
        Write-Host "  (restart required for $feat -- the windows-restart provisioner after this script handles it)"
    }
}

Write-Host "=== 10-desktop-admin-tools: OK ==="
