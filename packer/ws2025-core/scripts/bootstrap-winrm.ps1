# bootstrap-winrm.ps1 -- FirstLogonCommands entry point.
#
# Runs ONCE at OOBE on the very first login of the nexusadmin account (see
# AutoLogon + FirstLogonCommands in Autounattend.xml.tpl). Its only job is
# to open a WinRM HTTP listener on 5985 and a matching firewall rule so
# Packer's winrm communicator can connect and take over from here.
#
# The listener is build-time only -- scripts/99-sysprep.ps1 tears it down
# before generalize so clones never ship with plaintext WinRM open.
#
# Logs land in C:\Windows\Temp\bootstrap-winrm.log for post-mortem if the
# Packer build hangs on "Waiting for WinRM to become available".

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\bootstrap-winrm.log'
Start-Transcript -Path $log -Append -Force | Out-Null

try {
    Write-Host "[$(Get-Date -Format s)] bootstrap-winrm.ps1 start"

    # 1. Make sure WinRM service is running + set to auto-start.
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM

    # 2. Quick-config equivalent -- but scripted so we never wait on a prompt.
    #    -Force suppresses the interactive "this changes firewall rules" prompt.
    winrm quickconfig -quiet -force | Out-Null

    # 3. Allow Basic auth + unencrypted -- Packer's default winrm communicator
    #    uses HTTP + Basic. Flipped off again in 99-sysprep.ps1 before sysprep.
    winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
    winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
    winrm set winrm/config/winrs    '@{MaxMemoryPerShellMB="1024"}' | Out-Null

    # 4. Confirm an HTTP listener exists on :5985. quickconfig usually creates
    #    one, but if the NIC came up after WinRM started the listener can be
    #    missing. Create it idempotently.
    $listeners = winrm enumerate winrm/config/listener 2>$null
    if ($listeners -notmatch 'Transport = HTTP') {
        winrm create winrm/config/Listener?Address=*+Transport=HTTP | Out-Null
    }

    # 5. Firewall rule for 5985 in + 5986 in (5986 unused now, reserved for
    #    HTTPS post-cert rollout). Scope = any during build; 03-nexus-firewall.ps1
    #    re-scopes to VMnet11 only.
    New-NetFirewallRule -Name 'WinRM-HTTP-In-Build' `
        -DisplayName 'WinRM HTTP (build-time)' `
        -Protocol TCP -LocalPort 5985 -Direction Inbound -Action Allow `
        -Profile Any -ErrorAction SilentlyContinue | Out-Null

    Write-Host "[$(Get-Date -Format s)] bootstrap-winrm.ps1 done -- listener up"
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
