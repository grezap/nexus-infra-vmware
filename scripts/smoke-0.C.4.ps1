#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.C.4 smoke gate: verify the foundation env's AD DS hardening overlays
  + build-host reachability invariant.

.DESCRIPTION
  Run AFTER `make foundation-apply` (or `terraform apply` directly) returns
  clean. Validates all four 0.C.4 overlays against their expected post-apply
  state, plus carry-forward sanity (DC + jumpbox still healthy from 0.C.2/3),
  plus the build-host reachability invariant from
  memory/feedback_lab_host_reachability.md (every fleet VM stays reachable
  on TCP/22 and TCP/3389 from the build host).

  Exits 0 on all-green, 1 if any check failed -- so it can wire into CI or
  a `make foundation-smoke` target.

.PARAMETER DcIp
  IP of dc-nexus on VMnet11. Default: 192.168.70.240 (foundation env default).

.PARAMETER JumpboxIp
  IP of nexus-jumpbox on VMnet11. Default: 192.168.70.241.

.PARAMETER Domain
  AD DS domain FQDN. Default: nexus.lab. Override if var.ad_domain was changed.

.PARAMETER MinPasswordLength
  Expected MinPasswordLength on the Default Domain Policy. Default: 12.

.PARAMETER LockoutThreshold
  Expected LockoutThreshold. Default: 5.

.PARAMETER LockoutMinutes
  Expected LockoutDuration in minutes. Default: 15.

.PARAMETER MaxPasswordAgeDays
  Expected MaxPasswordAge in days; 0 = never expire. Default: 0.

.NOTES
  Assumes handbook docs/handbook.md §0.4 SSH client setup is done -- bare
  `ssh nexusadmin@<ip>` works zero-touch via ~/.ssh/config + ssh-agent.

  See also:
    docs/handbook.md §1f         (overlay reference + selective ops)
    memory/feedback_lab_host_reachability.md  (the SSH/RDP invariant)
#>

[CmdletBinding()]
param(
    [string]$DcIp              = '192.168.70.240',
    [string]$JumpboxIp         = '192.168.70.241',
    [string]$Domain            = 'nexus.lab',
    [int]   $MinPasswordLength = 12,
    [int]   $LockoutThreshold  = 5,
    [int]   $LockoutMinutes    = 15,
    [int]   $MaxPasswordAgeDays = 0
)

$ErrorActionPreference = 'Continue'
$script:failures = @()

function Section([string]$title) {
    Write-Host ""
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Check {
    param(
        [Parameter(Mandatory)][string]      $Label,
        [Parameter(Mandatory)][scriptblock] $Probe,
        [Parameter(Mandatory)][scriptblock] $Predicate
    )
    $out = & $Probe 2>&1 | Out-String
    $ok  = & $Predicate $out
    if ($ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        Write-Host ($out.Trim() -split "`r?`n" | ForEach-Object { "       $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
        $script:failures += $Label
    }
}

# Wrapper for SSH-to-DC PowerShell one-liners. Keeps the noisy quoting in one place.
function Invoke-DcPwsh([string]$Command) {
    ssh nexusadmin@$DcIp "powershell -NoProfile -Command `"$Command`""
}
function Invoke-JumpboxPwsh([string]$Command) {
    ssh nexusadmin@$JumpboxIp "powershell -NoProfile -Command `"$Command`""
}

Write-Host "Phase 0.C.4 smoke gate: dc=$DcIp, jumpbox=$JumpboxIp, domain=$Domain" -ForegroundColor White

# ─── 1. Build-host reachability invariant (FIRST -- if this fails the rest is moot)
Section "Build-host reachability (SSH/22 + RDP/3389)"
foreach ($vm in @(
        @{ Name = 'dc-nexus';      Ip = $DcIp },
        @{ Name = 'nexus-jumpbox'; Ip = $JumpboxIp }
    )) {
    foreach ($port in @(22, 3389)) {
        $vmRef = $vm; $portRef = $port
        Check "$($vmRef.Name) $($vmRef.Ip):$portRef reachable" `
            { Test-NetConnection -ComputerName $vmRef.Ip -Port $portRef -InformationLevel Quiet -WarningAction SilentlyContinue } `
            { param($o) $o.Trim() -eq 'True' }
    }
}

# ─── 2. OU layout + jumpbox move (var.enable_dc_ous)
Section "OU layout + jumpbox move"
$ouNames = @('Servers', 'Workstations', 'ServiceAccounts', 'Groups')
$ouRaw   = Invoke-DcPwsh 'Get-ADOrganizationalUnit -Filter * | Select-Object -ExpandProperty Name'
$ouLines = ($ouRaw -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
foreach ($name in $ouNames) {
    $nameRef = $name
    Check "OU=$nameRef exists" `
        { $ouLines } `
        { param($o) $ouLines -contains $nameRef }
}
Check "nexus-jumpbox is in OU=Servers,DC=nexus,DC=lab" `
    { Invoke-DcPwsh '(Get-ADComputer nexus-jumpbox).DistinguishedName' } `
    { param($o) $o -match 'OU=Servers,DC=nexus,DC=lab' }

# ─── 3. Default Domain Password Policy (var.enable_dc_password_policy)
Section "Default Domain Password Policy"
Check "MinPasswordLength = $MinPasswordLength" `
    { Invoke-DcPwsh '(Get-ADDefaultDomainPasswordPolicy).MinPasswordLength' } `
    { param($o) $o.Trim() -eq "$MinPasswordLength" }
Check "LockoutThreshold = $LockoutThreshold" `
    { Invoke-DcPwsh '(Get-ADDefaultDomainPasswordPolicy).LockoutThreshold' } `
    { param($o) $o.Trim() -eq "$LockoutThreshold" }
Check "LockoutDuration = $LockoutMinutes min" `
    { Invoke-DcPwsh '[int](Get-ADDefaultDomainPasswordPolicy).LockoutDuration.TotalMinutes' } `
    { param($o) $o.Trim() -eq "$LockoutMinutes" }
Check "LockoutObservationWindow = $LockoutMinutes min" `
    { Invoke-DcPwsh '[int](Get-ADDefaultDomainPasswordPolicy).LockoutObservationWindow.TotalMinutes' } `
    { param($o) $o.Trim() -eq "$LockoutMinutes" }
Check "MaxPasswordAge = $MaxPasswordAgeDays days $(if ($MaxPasswordAgeDays -eq 0) { '(never)' })" `
    { Invoke-DcPwsh '[int](Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge.TotalDays' } `
    { param($o) $o.Trim() -eq "$MaxPasswordAgeDays" }
Check "ComplexityEnabled = True" `
    { Invoke-DcPwsh '(Get-ADDefaultDomainPasswordPolicy).ComplexityEnabled' } `
    { param($o) $o.Trim() -eq 'True' }

# ─── 4. Reverse DNS zone + PTR records (var.enable_dc_reverse_dns)
Section "Reverse DNS zone + PTR records"
Check "zone 70.168.192.in-addr.arpa exists" `
    { Invoke-DcPwsh '(Get-DnsServerZone -Name 70.168.192.in-addr.arpa).ZoneName' } `
    { param($o) $o -match '70\.168\.192\.in-addr\.arpa' }
Check "zone is AD-integrated (IsDsIntegrated=True)" `
    { Invoke-DcPwsh '(Get-DnsServerZone -Name 70.168.192.in-addr.arpa).IsDsIntegrated' } `
    { param($o) $o.Trim() -eq 'True' }
Check "PTR 240 -> dc-nexus.$Domain" `
    { Invoke-DcPwsh "(Resolve-DnsName -Name $DcIp -Server $DcIp -Type PTR).NameHost" } `
    { param($o) $o -match "dc-nexus\.$([regex]::Escape($Domain))" }
Check "PTR 241 -> nexus-jumpbox.$Domain" `
    { Invoke-DcPwsh "(Resolve-DnsName -Name $JumpboxIp -Server $DcIp -Type PTR).NameHost" } `
    { param($o) $o -match "nexus-jumpbox\.$([regex]::Escape($Domain))" }

# ─── 5. W32Time PDC authoritative config (var.enable_dc_time_authoritative)
Section "W32Time PDC authoritative config"
$w32Cfg = Invoke-DcPwsh 'w32tm /query /configuration'
$w32St  = Invoke-DcPwsh 'w32tm /query /status'

# Default peer list -- if the user overrode var.dc_time_external_peers we still
# want the smoke to pass on the new value. Three of the four default peers MUST
# be present (time.windows.com is permitted-to-flap; the others are stable).
Check "NtpServer includes time.cloudflare.com" `
    { $w32Cfg } { param($o) $o -match 'time\.cloudflare\.com,0x8' }
Check "NtpServer includes time.nist.gov" `
    { $w32Cfg } { param($o) $o -match 'time\.nist\.gov,0x8' }
Check "NtpServer includes pool.ntp.org" `
    { $w32Cfg } { param($o) $o -match 'pool\.ntp\.org,0x8' }
Check "Type = NTP (manual peer list)" `
    { $w32Cfg } { param($o) $o -match 'Type:\s*NTP' }
Check "AnnounceFlags includes Reliable (=5)" `
    { $w32Cfg } { param($o) $o -match 'AnnounceFlags:\s*5' }

Check "Source != Local CMOS Clock (PDC actually synced)" `
    { $w32St } { param($o) $o -notmatch 'Local CMOS Clock' }
Check "Stratum < 16 (synced -- 16 = unsynchronized)" `
    { $w32St } {
        param($o)
        if ($o -match 'Stratum:\s*(\d+)') { [int]$matches[1] -lt 16 } else { $false }
    }

# ─── 6. Carry-forward sanity (DC + jumpbox still healthy after hardening)
Section "Carry-forward: 0.C.2/0.C.3 still healthy"
Check "DC: Get-ADDomain.Forest = $Domain" `
    { Invoke-DcPwsh '(Get-ADDomain).Forest' } `
    { param($o) $o.Trim() -eq $Domain }
Check "DC: ADWS service Running" `
    { Invoke-DcPwsh '(Get-Service ADWS).Status' } `
    { param($o) $o.Trim() -eq 'Running' }
Check "jumpbox: PartOfDomain = True" `
    { Invoke-JumpboxPwsh '(Get-WmiObject Win32_ComputerSystem).PartOfDomain' } `
    { param($o) $o.Trim() -eq 'True' }
Check "jumpbox: Domain = $Domain" `
    { Invoke-JumpboxPwsh '(Get-WmiObject Win32_ComputerSystem).Domain' } `
    { param($o) $o.Trim() -eq $Domain }
Check "jumpbox: nltest /dsgetdc returns dc-nexus" `
    { Invoke-JumpboxPwsh "nltest /dsgetdc:$Domain" } `
    { param($o) $o -match 'DC:\s*\\\\dc-nexus|DC:\s*\\\\DC-NEXUS' }

# ─── Summary
Write-Host ""
$total = 0
# Re-count via the failures list -- we don't track total separately to keep the
# Check helper simple. Instead, summary just reports the failure count.
if ($script:failures.Count -eq 0) {
    Write-Host "ALL SMOKE CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
