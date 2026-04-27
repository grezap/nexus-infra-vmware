# 10-win11ent-client-tools.ps1 -- Win11 developer-workstation delta
#
# Installs the client-side tooling that justifies a separate win11ent
# template over ws2025-desktop:
#   - .NET 10 SDK             nexus-desk app development (WinForms/WPF/WinUI 3)
#   - .NET 10 Desktop Runtime running compiled WPF/WinForms binaries
#   - Windows App SDK runtime WinUI 3 demo apps
#   - Windows Terminal        latest version (Win11 22H2+ pre-ships an older one)
#
# .NET goes through Microsoft's official dotnet-install.ps1 rather than
# winget. The winget Microsoft.DotNet.SDK.10 manifest hit
# 0x8a15000f "Data required by the source is missing" on a clean Win11
# build (download succeeded but installer's secondary content fetch broke);
# dotnet-install.ps1 pulls direct from the .NET CDN without a winget
# intermediary and is the Microsoft-supported scripted-install path.
#
# WinAppSDK + Terminal stay on winget because they're smaller, single-shot
# downloads. We `winget source reset --force` upfront in case the source
# index got into the same broken state .NET surfaced.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "=== 10-win11ent-client-tools ==="

# -- 1. .NET 10 SDK + Desktop Runtime via dotnet-install.ps1 --------------
$installer = Join-Path $env:TEMP 'dotnet-install.ps1'
$installDir = 'C:\Program Files\dotnet'

Write-Host "Downloading dotnet-install.ps1"
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer -UseBasicParsing

Write-Host "Installing .NET 10 SDK to $installDir"
& $installer -Channel '10.0' -InstallDir $installDir -NoPath
if ($LASTEXITCODE -ne 0) { throw "dotnet-install.ps1 SDK failed (exit $LASTEXITCODE)" }

Write-Host "Installing .NET 10 Desktop Runtime to $installDir"
& $installer -Channel '10.0' -InstallDir $installDir -Runtime windowsdesktop -NoPath
if ($LASTEXITCODE -ne 0) { throw "dotnet-install.ps1 Desktop Runtime failed (exit $LASTEXITCODE)" }

# -NoPath above skips the script's own PATH munging (which only edits
# the *user* PATH); we want the *machine* PATH so every clone's account
# inherits dotnet, not just the build-time nexusadmin.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$installDir", 'Machine')
    Write-Host "Added $installDir to machine PATH"
}

# -- 2. WindowsAppRuntime + Windows Terminal via winget -------------------
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    throw "winget not found on PATH -- Microsoft.DesktopAppInstaller did not provision."
}

# Reset source first to clear the kind of cache corruption that broke
# Microsoft.DotNet.SDK.10. Idempotent and cheap.
& winget source reset --force --disable-interactivity 2>&1 | Out-Null

$srcOk = $false
foreach ($attempt in 1, 2) {
    try {
        & winget source update --disable-interactivity 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $srcOk = $true; break }
    }
    catch {
        Write-Verbose "winget source update attempt $attempt threw: $_"
    }
    Start-Sleep -Seconds 10
}
if (-not $srcOk) {
    throw "winget source update failed twice -- check network or App Installer registration."
}

$packages = @(
    @{ Id = 'Microsoft.WindowsAppRuntime.1.5'; Name = 'Windows App SDK 1.5 runtime' },
    @{ Id = 'Microsoft.WindowsTerminal';       Name = 'Windows Terminal' }
)

foreach ($pkg in $packages) {
    Write-Host "Installing $($pkg.Name) ($($pkg.Id)) ..."
    & winget install --exact --id $pkg.Id `
        --accept-source-agreements --accept-package-agreements `
        --silent --disable-interactivity --source winget
    # winget exit codes: 0 = installed, -1978335189 = already installed.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget install $($pkg.Id) failed with exit code $LASTEXITCODE"
    }
}

Write-Host "=== 10-win11ent-client-tools: OK ==="
