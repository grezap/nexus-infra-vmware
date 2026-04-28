# 05-install-openssh.ps1 -- Win11-specific pre-step before _shared/01-nexus-identity
#
# Win11 client SKUs ship without the OpenSSH.Server FOD payload baked in,
# so `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` has to
# download from Windows Update. That call routinely takes 20+ minutes and
# trips Packer's WinRM session timeouts (build #5 hit "wsarecv: connection
# attempt failed" mid-Add-WindowsCapability). WS2025 doesn't see this
# because the FOD is already in the install.wim.
#
# We install Win32-OpenSSH directly from the Microsoft GitHub release --
# same binaries as the FOD, but ~2 min instead of 20+, and zero dependency
# on Windows Update reachability. Once sshd is registered as a service,
# 01-nexus-identity.ps1's Get-Service sshd check skips the FOD path.

$ErrorActionPreference = 'Stop'
Write-Host "=== 05-install-openssh ==="

if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
    Write-Host "sshd service already exists -- skipping Win32-OpenSSH download"
    return
}

# Pinned to v9.5.0.0p1-Beta. Newer Win32-OpenSSH releases (v9.8+, including
# v10.0p2 which is currently `latest`) introduced a parent/sshd-session.exe
# process split, and on Win11 24H2 (build 26200) clones post-sysprep the
# spawned sshd-session.exe child immediately crashes with
# STATUS_ACCESS_VIOLATION (0xC0000005) before the SSH protocol can begin.
# v9.5 keeps the single-binary architecture and works reliably.
$url     = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip'
$zipPath = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
$extract = Join-Path $env:TEMP 'OpenSSH-Win64-extract'
$dest    = 'C:\Program Files\OpenSSH'

Write-Host "Downloading $url"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
Expand-Archive -Path $zipPath -DestinationPath $extract -Force

$src = Get-ChildItem -Path $extract -Directory | Where-Object Name -like 'OpenSSH-*' | Select-Object -First 1
if (-not $src) { throw "Could not locate extracted OpenSSH-* directory under $extract" }

if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
Move-Item -Path $src.FullName -Destination $dest

# install-sshd.ps1 registers the sshd + ssh-agent services with the SCM,
# sets ACLs on the host keys, and adds C:\Program Files\OpenSSH to the
# system PATH for sftp-server.exe lookup by sshd_config Subsystem.
& "$dest\install-sshd.ps1"

# Persist PATH so sftp etc. resolve in subsequent provisioner sessions.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$dest*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$dest", 'Machine')
}

# Idempotency cleanup so a re-run is cheap.
Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue

Write-Host "=== 05-install-openssh: OK (Win32-OpenSSH installed at $dest) ==="
