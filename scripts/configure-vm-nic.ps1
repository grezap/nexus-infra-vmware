<#
.SYNOPSIS
    Rewrite a cloned .vmx to attach a single NIC with a pinned MAC.

.DESCRIPTION
    NexusPlatform's Packer templates are built with `vmx_remove_ethernet_interfaces
    = true` so the resulting template has zero NIC entries. Terraform's modules/vm/
    calls this script after `vmrun clone` to add exactly one NIC, attached to the
    caller-chosen VMnet (typically VMnet11 for lab VMs), with a caller-chosen MAC.

    For multi-NIC VMs (e.g. nexus-gateway), see scripts/configure-gateway-nics.ps1.

.PARAMETER VmxPath
    Absolute path to the cloned .vmx.

.PARAMETER Vnet
    VMware network name. Examples: "vmnet11" (lab), "vmnet10" (backplane),
    "vmnet1" (Workstation's default host-only), "bridged" (physical LAN).
    Case-insensitive. Value is written as connectionType=custom + vnet=<name>
    except "bridged"/"nat"/"hostonly" which map to the built-in connection
    types (no vnet line).

.PARAMETER Mac
    Static MAC. VMware requires the 00:50:56 OUI and fourth byte in 0x00-0x3F
    for the user-managed range.

.EXAMPLE
    ./configure-vm-nic.ps1 `
        -VmxPath H:/VMS/NexusPlatform/90-smoke/deb13-smoke/deb13-smoke.vmx `
        -Vnet    VMnet11 `
        -Mac     00:50:56:3F:00:20
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmxPath,
    [Parameter(Mandatory)][string]$Vnet,
    [Parameter(Mandatory)][string]$Mac
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $VmxPath)) {
    throw "VMX not found at $VmxPath"
}

$lines = Get-Content $VmxPath

# Strip any existing ethernet* entries so we write from a clean slate.
$lines = $lines | Where-Object { $_ -notmatch '^ethernet[0-9]+\.' }

$vnetLower = $Vnet.ToLower()
$builtin   = @{ 'bridged' = 'bridged'; 'nat' = 'nat'; 'hostonly' = 'hostonly' }

if ($builtin.ContainsKey($vnetLower)) {
    $nic = @(
        'ethernet0.present = "TRUE"',
        'ethernet0.virtualDev = "vmxnet3"',
        "ethernet0.connectionType = `"$($builtin[$vnetLower])`"",
        'ethernet0.addressType = "static"',
        "ethernet0.address = `"$Mac`"",
        'ethernet0.wakeOnPcktRcv = "FALSE"',
        'ethernet0.startConnected = "TRUE"'
    )
} else {
    # custom vnet — e.g. VMnet10/VMnet11
    $nic = @(
        'ethernet0.present = "TRUE"',
        'ethernet0.virtualDev = "vmxnet3"',
        'ethernet0.connectionType = "custom"',
        "ethernet0.vnet = `"$Vnet`"",
        'ethernet0.addressType = "static"',
        "ethernet0.address = `"$Mac`"",
        'ethernet0.wakeOnPcktRcv = "FALSE"',
        'ethernet0.startConnected = "TRUE"'
    )
}

$lines = @($lines) + $nic

# Write atomically (tmp + move) so a crashed script can't leave half a .vmx.
$tmp = "$VmxPath.tmp"
$lines | Set-Content -Path $tmp -Encoding ASCII
Move-Item -Path $tmp -Destination $VmxPath -Force

Write-Host "[configure-vm-nic] wrote 1 NIC to $VmxPath" -ForegroundColor Green
Write-Host "  ethernet0  vnet=$Vnet  MAC=$Mac"
