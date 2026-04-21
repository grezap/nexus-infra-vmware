<#
.SYNOPSIS
    Rewrite a nexus-gateway .vmx to have the correct 3-NIC topology.

.DESCRIPTION
    The vmworkstation Terraform provider (v1.2.0) clones a template but does not
    expose per-NIC network-type or MAC configuration. This script edits the .vmx
    in place so that the VM comes up with:

        ethernet0  → bridged      (physical LAN — internet egress)
        ethernet1  → VMnet11      (192.168.70.1 — lab gateway)
        ethernet2  → VMnet10      (192.168.10.1 — backplane)

    MAC addresses are pinned (passed in) so interface names are stable across
    reboots (systemd .link files match by MAC path — see Ansible role).

.PARAMETER VmxPath
    Absolute path to nexus-gateway.vmx.

.PARAMETER MacNic0, MacNic1, MacNic2
    Static MACs. VMware requires the 00:50:56 OUI and the next byte in
    0x00-0x3F for the user-controlled range.

.EXAMPLE
    ./configure-gateway-nics.ps1 -VmxPath H:/VMS/NexusPlatform/00-edge/nexus-gateway/nexus-gateway.vmx `
                                 -MacNic0 00:50:56:3F:00:10 `
                                 -MacNic1 00:50:56:3F:00:11 `
                                 -MacNic2 00:50:56:3F:00:12
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmxPath,
    [Parameter(Mandatory)][string]$MacNic0,
    [Parameter(Mandatory)][string]$MacNic1,
    [Parameter(Mandatory)][string]$MacNic2
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $VmxPath)) {
    throw "VMX not found at $VmxPath"
}

function Set-VmxKey {
    param([string[]]$Lines, [string]$Key, [string]$Value)
    $escKey = [regex]::Escape($Key)
    $newLine = "$Key = `"$Value`""
    if ($Lines -match "^$escKey\s*=") {
        return $Lines -replace "^$escKey\s*=.*$", $newLine
    }
    return $Lines + $newLine
}

$lines = Get-Content $VmxPath

# Strip existing ethernet* entries, then re-add clean
$lines = $lines | Where-Object { $_ -notmatch '^ethernet[0-9]+\.' }

$nic0 = @(
    'ethernet0.present = "TRUE"',
    'ethernet0.virtualDev = "vmxnet3"',
    'ethernet0.connectionType = "bridged"',
    'ethernet0.addressType = "static"',
    "ethernet0.address = `"$MacNic0`"",
    'ethernet0.wakeOnPcktRcv = "FALSE"',
    'ethernet0.startConnected = "TRUE"'
)
$nic1 = @(
    'ethernet1.present = "TRUE"',
    'ethernet1.virtualDev = "vmxnet3"',
    'ethernet1.connectionType = "custom"',
    'ethernet1.vnet = "VMnet11"',
    'ethernet1.addressType = "static"',
    "ethernet1.address = `"$MacNic1`"",
    'ethernet1.wakeOnPcktRcv = "FALSE"',
    'ethernet1.startConnected = "TRUE"'
)
$nic2 = @(
    'ethernet2.present = "TRUE"',
    'ethernet2.virtualDev = "vmxnet3"',
    'ethernet2.connectionType = "custom"',
    'ethernet2.vnet = "VMnet10"',
    'ethernet2.addressType = "static"',
    "ethernet2.address = `"$MacNic2`"",
    'ethernet2.wakeOnPcktRcv = "FALSE"',
    'ethernet2.startConnected = "TRUE"'
)

$lines = @($lines) + $nic0 + $nic1 + $nic2

# Normalize line endings and write atomically
$tmp = "$VmxPath.tmp"
$lines | Set-Content -Path $tmp -Encoding ASCII
Move-Item -Path $tmp -Destination $VmxPath -Force

Write-Host "[configure-gateway-nics] wrote 3 NICs to $VmxPath" -ForegroundColor Green
Write-Host "  ethernet0 bridged    MAC=$MacNic0"
Write-Host "  ethernet1 VMnet11    MAC=$MacNic1"
Write-Host "  ethernet2 VMnet10    MAC=$MacNic2"
