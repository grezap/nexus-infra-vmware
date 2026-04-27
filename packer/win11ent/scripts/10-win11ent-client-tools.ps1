# 10-win11ent-client-tools.ps1 -- Win11 developer-workstation delta
#
# Installs the client-side tooling that justifies a separate win11ent
# template over ws2025-desktop:
#   - .NET 10 SDK             nexus-desk app development (WinForms/WPF/WinUI 3)
#   - .NET 10 Desktop Runtime running compiled WPF/WinForms binaries
#   - Windows App SDK runtime WinUI 3 demo apps
#   - Windows Terminal        pre-installed on Win11 22H2+; we don't reinstall
#
# Both binaries come from direct Microsoft URLs rather than winget. Win11
# Enterprise Evaluation hits 0x8a15000f "Data required by the source is
# missing" on every winget Microsoft.* manifest -- the initial download
# succeeds but the installer's secondary content fetch fails. The bug
# surfaced first on Microsoft.DotNet.SDK.10, then reproduced on
# Microsoft.WindowsAppRuntime.1.5 even after `winget source reset --force`.
# Direct downloads from dot.net + aka.ms shortlinks bypass the broken
# winget content-delivery path entirely.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "=== 10-win11ent-client-tools ==="

# -- 1. .NET 10 SDK + Desktop Runtime via dotnet-install.ps1 --------------
$installer  = Join-Path $env:TEMP 'dotnet-install.ps1'
$installDir = 'C:\Program Files\dotnet'

Write-Host "Downloading dotnet-install.ps1"
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer -UseBasicParsing

Write-Host "Installing .NET 10 SDK to $installDir"
& $installer -Channel '10.0' -InstallDir $installDir -NoPath
# dotnet-install.ps1 throws on error under our $ErrorActionPreference='Stop',
# so reaching this line means success. Don't check $LASTEXITCODE -- it's not
# set by .ps1 invocations the way it is for native .exe calls (would compare
# $null against 0 and falsely throw "exit ").
if (-not (Test-Path "$installDir\dotnet.exe")) {
    throw "dotnet-install.ps1 SDK ran but $installDir\dotnet.exe missing"
}

Write-Host "Installing .NET 10 Desktop Runtime to $installDir"
& $installer -Channel '10.0' -InstallDir $installDir -Runtime windowsdesktop -NoPath
$runtimes = & "$installDir\dotnet.exe" --list-runtimes 2>&1 | Out-String
if ($runtimes -notmatch 'Microsoft\.WindowsDesktop\.App 10\.') {
    throw "Desktop Runtime 10.x not found after install -- runtimes:`n$runtimes"
}

# -NoPath above skips the script's own PATH munging (which only edits
# the *user* PATH); we want the *machine* PATH so every clone's account
# inherits dotnet, not just the build-time nexusadmin.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$installDir", 'Machine')
    Write-Host "Added $installDir to machine PATH"
}

# -- 2. Windows App SDK 1.6 runtime via direct download -------------------
# aka.ms shortlink redirects to the latest 1.6 runtime installer. The
# stand-alone installer is a self-contained MSIX/MSI that doesn't reach
# back to Windows Update -- no winget involvement.
$wasInstaller = Join-Path $env:TEMP 'windowsappruntimeinstall-x64.exe'
$wasUrl       = 'https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-x64.exe'

Write-Host "Downloading WindowsAppRuntime 1.6 from $wasUrl"
Invoke-WebRequest -Uri $wasUrl -OutFile $wasInstaller -UseBasicParsing

Write-Host "Installing WindowsAppRuntime (silent)"
$proc = Start-Process -FilePath $wasInstaller -ArgumentList '--quiet' -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    throw "WindowsAppRuntime installer failed (exit $($proc.ExitCode))"
}

# -- 3. Windows Terminal: pre-installed on Win11 22H2+ -------------------
# Win11 ships Windows Terminal as the default console host since 22H2 and
# Microsoft.WindowsTerminal is a built-in Appx package. No install needed;
# users see the latest Store update on first run. Confirm presence so the
# template's exit gate (`(Get-Command wt.exe).Source` resolves) holds.
$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if (-not $wt) {
    Write-Host "WARNING: wt.exe not on PATH (unexpected on Win11 22H2+); smoke gate may need adjustment."
} else {
    Write-Host "Windows Terminal present at $($wt.Source)"
}

Write-Host "=== 10-win11ent-client-tools: OK ==="
