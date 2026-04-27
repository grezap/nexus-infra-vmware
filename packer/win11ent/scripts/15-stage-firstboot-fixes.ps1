# 15-stage-firstboot-fixes.ps1 -- seed C:\Windows\Setup\Scripts\ with hooks
# that run ONCE on the clone's first boot (Microsoft's documented sysprep
# post-OOBE entry point). Runs on the *build* VM, right before 99-sysprep.
#
# Today this stages a single fix: re-grant SeAssignPrimaryTokenPrivilege
# and SeIncreaseQuotaPrivilege to NT SERVICE\sshd. sysprep /generalize
# strips both from the sshd virtual service account, and Win32-OpenSSH
# (the GitHub-release sshd we install in 05-install-openssh.ps1) needs
# them to spawn user-session subprocesses. Without them, every SSH
# connection to a clone resets immediately after SSH2_MSG_SERVICE_ACCEPT
# (verified on win11ent-smoke during Phase 0.B.6 closeout).
#
# Why SetupComplete.cmd:
#   - Runs as SYSTEM with the full token (privileges aren't filtered).
#   - Fires exactly once, on the FIRST boot after sysprep, before any
#     interactive logon. Subsequent boots don't re-run it.
#   - C:\Windows\Setup\Scripts is preserved through sysprep /generalize.
#
# Why this lives in packer/win11ent/ and not packer/_shared/:
#   The privilege-strip is a Win11 + Win32-OpenSSH interaction. WS2025
#   uses the FOD-installed sshd (Server's install.wim ships it) which
#   doesn't lose these privileges on /generalize. Server clones don't
#   need this and the SetupComplete.cmd hook would just be cargo.

$ErrorActionPreference = 'Stop'
$scriptsDir = "$env:windir\Setup\Scripts"

Write-Host "=== 15-stage-firstboot-fixes ==="

New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null

# -- fix-sshd-privileges.ps1 (runs on clone first boot) ------------------
$fixScript = @'
# fix-sshd-privileges.ps1 -- runs ONCE at clone first boot via
# %WINDIR%\Setup\Scripts\SetupComplete.cmd. Re-grants the two privileges
# sysprep /generalize strips from NT SERVICE\sshd, then restarts sshd so
# it picks them up before any client connects.
#
# Without this fix, every SSH connection to a clone of a sysprep'd Win11
# template resets right after SSH2_MSG_SERVICE_ACCEPT (sshd cannot spawn
# the user-session subprocess without SeAssignPrimaryTokenPrivilege).

$ErrorActionPreference = 'Stop'
$logDir = "$env:windir\Setup\Scripts"
$transcript = Join-Path $logDir 'fix-sshd-privileges.transcript.log'
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Host "[$(Get-Date -Format s)] fix-sshd-privileges start"

    # NT SERVICE\sshd virtual account SID is deterministic (derived from
    # the service name) -- translate via the NTAccount API rather than
    # parsing `sc.exe showsid` output.
    $sshdSid = ([System.Security.Principal.NTAccount]'NT SERVICE\sshd').Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Host "sshd SID: $sshdSid"

    $cfgPath = Join-Path $env:TEMP 'secpol.inf'
    $dbPath  = Join-Path $env:TEMP 'secpol.sdb'

    & secedit.exe /export /cfg $cfgPath /areas USER_RIGHTS /quiet
    if ($LASTEXITCODE -ne 0) { throw "secedit /export failed (exit $LASTEXITCODE)" }

    # secedit emits UTF-16 LE with BOM; Get-Content -Encoding Unicode handles it.
    $lines = Get-Content -Path $cfgPath -Encoding Unicode

    function Add-SidToPrivilege {
        param([string[]]$Lines, [string]$Privilege, [string]$Sid)
        $sidEntry = "*$Sid"
        $patched = @()
        $found = $false
        foreach ($line in $Lines) {
            if ($line -match "^${Privilege}\s*=\s*(.*)$") {
                $found = $true
                $rhs = $matches[1].Trim()
                if ($rhs -match [regex]::Escape($sidEntry)) {
                    Write-Host "  $Privilege already has $sidEntry"
                    $patched += $line
                } else {
                    $newRhs = if ([string]::IsNullOrWhiteSpace($rhs)) { $sidEntry } else { "$rhs,$sidEntry" }
                    Write-Host "  $Privilege : appending $sidEntry"
                    $patched += "$Privilege = $newRhs"
                }
            } else {
                $patched += $line
            }
        }
        if (-not $found) {
            $sectionIdx = -1
            for ($i = 0; $i -lt $patched.Count; $i++) {
                if ($patched[$i] -match '^\[Privilege Rights\]') { $sectionIdx = $i; break }
            }
            if ($sectionIdx -lt 0) { throw "[Privilege Rights] section not found in exported policy" }
            $head = if ($sectionIdx -ge 0) { $patched[0..$sectionIdx] } else { @() }
            $tail = if ($sectionIdx + 1 -le $patched.Count - 1) { $patched[($sectionIdx + 1)..($patched.Count - 1)] } else { @() }
            $patched = @($head) + "$Privilege = $sidEntry" + @($tail)
            Write-Host "  $Privilege : added (was absent)"
        }
        return , $patched
    }

    foreach ($priv in 'SeAssignPrimaryTokenPrivilege', 'SeIncreaseQuotaPrivilege') {
        $lines = Add-SidToPrivilege -Lines $lines -Privilege $priv -Sid $sshdSid
    }

    $lines | Out-File -FilePath $cfgPath -Encoding Unicode -Force

    & secedit.exe /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS /quiet
    if ($LASTEXITCODE -ne 0) { throw "secedit /configure failed (exit $LASTEXITCODE)" }

    Restart-Service -Name sshd -Force
    Write-Host "[$(Get-Date -Format s)] fix-sshd-privileges done -- sshd restarted"
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
'@

$fixScriptPath = Join-Path $scriptsDir 'fix-sshd-privileges.ps1'
[System.IO.File]::WriteAllText($fixScriptPath, $fixScript, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $fixScriptPath ($($fixScript.Length) chars)"

# -- SetupComplete.cmd (Microsoft's sysprep first-boot hook) -------------
# Path is fixed by Microsoft: %WINDIR%\Setup\Scripts\SetupComplete.cmd.
# Sysprep invokes this exactly once after specialize+oobe, before any
# interactive logon, running as SYSTEM with the full token.
$setupCmd = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\fix-sshd-privileges.ps1 > C:\Windows\Setup\Scripts\fix-sshd-privileges.log 2>&1
exit /b 0
'@

$setupCmdPath = Join-Path $scriptsDir 'SetupComplete.cmd'
[System.IO.File]::WriteAllText($setupCmdPath, $setupCmd, [System.Text.ASCIIEncoding]::new())
Write-Host "Wrote $setupCmdPath"

Write-Host "=== 15-stage-firstboot-fixes: OK ==="
