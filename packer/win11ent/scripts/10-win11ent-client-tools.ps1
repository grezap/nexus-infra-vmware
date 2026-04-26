# 10-win11ent-client-tools.ps1 -- Win11 developer-workstation delta
#
# Installs the client-side tooling that justifies a separate win11ent
# template over ws2025-desktop:
#   - .NET 10 SDK             nexus-desk app development (WinForms/WPF/WinUI 3)
#   - .NET 10 Desktop Runtime running compiled WPF/WinForms binaries
#   - Windows App SDK runtime WinUI 3 demo apps
#   - Windows Terminal        default shell for the nexusadmin desktop session
#
# winget-driven so the manifests track upstream releases automatically.
# VS Code is intentionally NOT installed at template-time -- it's a per-user
# tool, not a fleet baseline; clones layer it on via Ansible if needed.
#
# winget caveat on freshly-installed Win11: the App Installer source needs
# to resolve before the first install can run. We force a `winget source
# update` upfront and retry once if it fails (transient registration race).

$ErrorActionPreference = 'Stop'

Write-Host "=== 10-win11ent-client-tools ==="

# -- 1. Verify winget is on PATH and the App Installer source is ready ----
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    throw "winget not found on PATH -- Microsoft.DesktopAppInstaller did not provision. Check Win11 Enterprise SKU."
}

# Force the source registration to settle. On a fresh OOBE, the first
# winget call sometimes errors with "Failed in attempting to update the
# source: winget" -- retry once after a short wait.
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

# -- 2. Install developer-workstation packages ----------------------------
$packages = @(
    @{ Id = 'Microsoft.DotNet.SDK.10';             Name = '.NET 10 SDK' },
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.10';  Name = '.NET 10 Desktop Runtime' },
    @{ Id = 'Microsoft.WindowsAppRuntime.1.5';     Name = 'Windows App SDK 1.5 runtime' },
    @{ Id = 'Microsoft.WindowsTerminal';           Name = 'Windows Terminal' }
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
