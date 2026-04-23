# 00-install-vmware-tools.ps1
#
# Mount C:\Windows\Temp\windows.iso (uploaded by Packer via tools_upload_flavor=windows)
# and silently install VMware Tools. A follow-up windows-restart provisioner
# reboots so subsequent scripts see the Tools-aware kernel shim + time sync.

$ErrorActionPreference = 'Stop'
$iso = 'C:\Windows\Temp\windows.iso'
if (-not (Test-Path $iso)) {
    throw "Expected VMware Tools ISO at $iso -- Packer upload failed?"
}

Write-Host "Mounting $iso"
$mount = Mount-DiskImage -ImagePath $iso -PassThru
$drive = ($mount | Get-Volume).DriveLetter
$setup = "${drive}:\setup64.exe"
if (-not (Test-Path $setup)) {
    throw "setup64.exe not found on mounted Tools ISO at ${drive}:"
}

Write-Host "Installing VMware Tools (silent, no reboot -- handled by Packer)"
$setupArgs = @(
    '/S',                         # silent
    '/v',
    '/qn REBOOT=ReallySuppress'   # MSI quiet + suppress reboot
)
$p = Start-Process -FilePath $setup -ArgumentList $setupArgs -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) {
    throw "VMware Tools setup exited with $($p.ExitCode)"
}

Write-Host "Dismounting + cleaning up"
Dismount-DiskImage -ImagePath $iso | Out-Null
Remove-Item -Force $iso
Write-Host "VMware Tools install OK (exit=$($p.ExitCode))"
