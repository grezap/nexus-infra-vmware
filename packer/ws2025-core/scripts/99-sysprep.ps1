# 99-sysprep.ps1  --  final generalize before template shutdown
#
# Before running sysprep we:
#   1. Tear down the build-time WinRM HTTP listener + firewall rule (the
#      runtime remote-access path is OpenSSH, set up in 01-nexus-identity).
#   2. Clear event logs.
#   3. Remove Packer's working dir residue (uploaded files in C:\Windows\Temp).
#   4. Clear DNS cache so clones don't inherit the build-time NAT resolver.
#
# Then sysprep /generalize /oobe /shutdown leaves the VM powered off with a
# fresh SID + cloneable identity. Packer sees the VM power down and finalizes
# the .vmx.

$ErrorActionPreference = 'Continue'   # don't hard-fail on log-clear noise

Write-Host "=== 99-sysprep: teardown + generalize ==="

# -- 1. Remove build-time WinRM HTTP listener + firewall rule --------------
try {
    # Remove every HTTP listener (there should be one -- Address=*, Transport=HTTP)
    $listeners = & winrm enumerate winrm/config/listener 2>$null
    if ($listeners -match 'Transport = HTTP\s') {
        & winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null | Out-Null
    }
    Remove-NetFirewallRule -Name 'WinRM-HTTP-In-Build' -ErrorAction SilentlyContinue

    # Turn off Basic auth + unencrypted -- won't affect runtime (no listener)
    # but belt-and-braces in case someone manually re-creates one later.
    & winrm set winrm/config/service/auth '@{Basic="false"}' 2>$null | Out-Null
    & winrm set winrm/config/service '@{AllowUnencrypted="false"}' 2>$null | Out-Null
}
catch {
    Write-Host "WARN teardown WinRM: $($_.Exception.Message)"
}

# -- 2. Clear event logs --------------------------------------------------
wevtutil el | ForEach-Object {
    try { wevtutil cl "$_" 2>$null } catch { Write-Verbose "skip log $_" }
}

# -- 3. Nuke Packer working files -----------------------------------------
Remove-Item -Recurse -Force 'C:\Windows\Temp\*' -ErrorAction SilentlyContinue

# -- 4. Clear DNS cache --------------------------------------------------
Clear-DnsClientCache

# -- 5. sysprep /generalize /oobe /shutdown -------------------------------
# Use the Packer-for-Windows-recommended unattend to skip the OOBE on first
# clone boot -- it auto-creates an Administrator with the build password.
# Terraform post-clone will immediately rotate that via modules/vm/ before
# handing the VM off to the role overlay (Phase 0.D moves it to Vault).
$sysprepUnattend = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>UTC</TimeZone>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
'@
$unattendPath = 'C:\Windows\System32\Sysprep\unattend.xml'
Set-Content -Path $unattendPath -Value $sysprepUnattend -Encoding utf8

Write-Host "Starting sysprep /generalize /oobe /shutdown"
& "$env:WINDIR\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet /unattend:$unattendPath

# Sysprep takes the VM down itself. Give Packer something to watch -- it sees
# the VM power off via VMware Tools + closes out the build.
Start-Sleep -Seconds 120
