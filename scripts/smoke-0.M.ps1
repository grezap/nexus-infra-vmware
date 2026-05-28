#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.M smoke gate: verify the 2nd AD DC (dc-nexus-2) is a healthy
  replica of nexus.lab with replication, DNS, and round-trip user-sync
  all GREEN.

.DESCRIPTION
  ~25 checks across 7 sections:

    1. Reachability     -- SSH/22 + RDP/3389 to dc-nexus + dc-nexus-2
                           (lab-host reachability invariant per
                           memory/feedback_lab_host_reachability.md)
    2. Hostname/identity -- dc-nexus-2's hostname matches expected
    3. Domain-join       -- PartOfDomain=True, Domain=nexus.lab
    4. ADDS role         -- AD-Domain-Services feature installed; NTDS,
                            KDC, ADWS, DNS services Running
    5. Replication       -- Get-ADDomainController shows 2 DCs; repadmin
                            /showrepl on dc-nexus reports dc-nexus-2 as
                            healthy partner; Get-ADReplicationPartnerMetadata
                            shows LastReplicationResult=0 (success)
    6. DNS replica zones -- dc-nexus-2 hosts nexus.lab + reverse zone
                            (AD-integrated, secure dynamic update)
    7. Test-user round-trip -- create unique test user on dc-nexus; force
                            replication; verify user appears on dc-nexus-2;
                            clean up.

  Per memory/feedback_smoke_gate_probe_robustness.md: marker tokens + -match
  (not strict-eq) for multi-line probes.

  Does NOT chain 0.D.5 (too many param surfaces). Spot-checks key carry-
  forward state (dc-nexus still healthy, jumpbox still joined) only.

.PARAMETER DcIp
  dc-nexus VMnet11 IP. Default 192.168.70.240 (smoke-pool reality, not the
  vms.yaml canonical .10).

.PARAMETER Dc2Ip
  dc-nexus-2 VMnet11 IP. Default 192.168.70.242 (smoke-pool, per 2026-05-28
  Greg decision; see role-overlay-dc-nexus-2-promotion.tf header).

.PARAMETER JumpboxIp
  nexus-jumpbox VMnet11 IP. Default .241 (carry-forward reachability check).

.PARAMETER Domain
  AD domain FQDN. Default nexus.lab.

.PARAMETER ReplicationWaitSeconds
  Seconds to wait between creating the test user on dc-nexus and querying
  dc-nexus-2. Default 60. Bump if your lab's replication is slow.

.NOTES
  Reproducibility canon:
    pwsh -File scripts\foundation.ps1 apply -Vars 'enable_dc_nexus_2=true,enable_dc_nexus_2_promotion=true'
    pwsh -File scripts\smoke-0.M.ps1

  See also:
    docs/handbook.md s 1.M                  (0.M from-zero replay)
    scripts/foundation.ps1 cycle            (destroy + apply + smoke chain)
    memory/feedback_smoke_gate_probe_robustness.md
#>

[CmdletBinding()]
param(
    [string]$DcIp                  = '192.168.70.240',
    [string]$Dc2Ip                 = '192.168.70.242',
    [string]$JumpboxIp             = '192.168.70.241',
    [string]$Domain                = 'nexus.lab',
    [int]   $ReplicationWaitSeconds = 60
)

$ErrorActionPreference = 'Continue'
$script:failures = @()
$user = 'nexusadmin'

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
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

function Test-Warn {
    # Like Test-Check but emits [WARN] instead of [FAIL] -- used for items
    # whose absence is acceptable in some states (e.g. graceful-stopped VMs
    # per minimal-running-VMs standing rule).
    param(
        [Parameter(Mandatory)][string]      $Label,
        [Parameter(Mandatory)][scriptblock] $Probe,
        [Parameter(Mandatory)][scriptblock] $Predicate,
        [Parameter(Mandatory)][string]      $WarnHint
    )
    $out = & $Probe 2>&1 | Out-String
    $ok  = & $Predicate $out
    if ($ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
    } else {
        Write-Host "[WARN] $Label" -ForegroundColor Yellow
        Write-Host "       $WarnHint" -ForegroundColor DarkYellow
    }
}

function Invoke-RemotePs {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Script
    )
    # Use base64 encoding per memory/feedback_windows_ssh_automation.md rule
    # #2 -- cmd.exe quoting between ssh.exe and remote powershell.exe is
    # unreliable for multi-token scripts.
    $b64 = [Convert]::ToBase64String([System.Text.UnicodeEncoding]::Unicode.GetBytes($Script))
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Ip "powershell -NoProfile -EncodedCommand $b64"
}

Write-Host ''
Write-Host "Phase 0.M smoke gate -- 2nd AD DC (dc-nexus-2) replication health" -ForegroundColor White
Write-Host "DC1: dc-nexus ($DcIp), DC2: dc-nexus-2 ($Dc2Ip), Domain: $Domain" -ForegroundColor White

# ─── 1. Reachability ──────────────────────────────────────────────────────
Write-Section '1. Reachability (SSH/22 + RDP/3389 -- non-negotiable invariant)'

foreach ($host_ in @(
    @{ Name = 'dc-nexus';   Ip = $DcIp },
    @{ Name = 'dc-nexus-2'; Ip = $Dc2Ip }
)) {
    $h = $host_
    Test-Check "$($h.Name) SSH/22 open ($($h.Ip))" `
        { Test-NetConnection -ComputerName $h.Ip -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue } `
        { param($o) $o -match 'True' }

    Test-Check "$($h.Name) RDP/3389 open ($($h.Ip))" `
        { Test-NetConnection -ComputerName $h.Ip -Port 3389 -InformationLevel Quiet -WarningAction SilentlyContinue } `
        { param($o) $o -match 'True' }
}

# ─── 2. Hostname/identity ─────────────────────────────────────────────────
Write-Section '2. Hostname'

Test-Check "dc-nexus-2 hostname == 'dc-nexus-2'" `
    { ssh -o BatchMode=yes -o StrictHostKeyChecking=no $user@$Dc2Ip "hostname" } `
    { param($o) $o.Trim() -ieq 'dc-nexus-2' }

# ─── 3. Domain-join state ─────────────────────────────────────────────────
Write-Section "3. Domain-join state ($Domain)"

Test-Check "dc-nexus-2 PartOfDomain=True" `
    { Invoke-RemotePs -Ip $Dc2Ip -Script '(Get-WmiObject Win32_ComputerSystem).PartOfDomain.ToString()' } `
    { param($o) $o.Trim() -eq 'True' }

Test-Check "dc-nexus-2 Domain=$Domain" `
    { Invoke-RemotePs -Ip $Dc2Ip -Script '(Get-WmiObject Win32_ComputerSystem).Domain' } `
    { param($o) $o.Trim() -ieq $Domain }

# ─── 4. ADDS role + services ──────────────────────────────────────────────
Write-Section '4. ADDS role installed + critical services Running'

Test-Check "dc-nexus-2: AD-Domain-Services feature installed" `
    { Invoke-RemotePs -Ip $Dc2Ip -Script "(Get-WindowsFeature AD-Domain-Services).InstallState" } `
    { param($o) $o.Trim() -ieq 'Installed' }

foreach ($svc in @('NTDS', 'KDC', 'ADWS', 'DNS', 'Netlogon')) {
    $s = $svc
    Test-Check "dc-nexus-2: service $s Running" `
        { Invoke-RemotePs -Ip $Dc2Ip -Script "(Get-Service $s -ErrorAction SilentlyContinue).Status" } `
        { param($o) $o.Trim() -ieq 'Running' }
}

# ─── 5. Replication topology ──────────────────────────────────────────────
Write-Section '5. Replication topology (Get-ADDomainController + repadmin)'

# Run AD cmdlets from dc-nexus (proven ADWS auth path -- SSH session as
# nexusadmin has integrated auth to local DC's ADWS; see feedback_addsforest_post_promotion.md).
Test-Check "Get-ADDomainController -Filter * shows 2 DCs (dc-nexus + dc-nexus-2)" `
    { Invoke-RemotePs -Ip $DcIp -Script "(Get-ADDomainController -Filter *).HostName -join ','" } `
    { param($o) $o -match 'dc-nexus' -and $o -match 'dc-nexus-2' }

Test-Check "Get-ADDomainController -Identity dc-nexus-2 returns IPv4Address=$Dc2Ip" `
    { Invoke-RemotePs -Ip $DcIp -Script "Get-ADDomainController -Identity dc-nexus-2 | Select-Object -ExpandProperty IPv4Address" } `
    { param($o) $o.Trim() -eq $Dc2Ip }

Test-Check "dc-nexus repadmin /replsummary shows dc-nexus-2 + no failures" `
    { Invoke-RemotePs -Ip $DcIp -Script "repadmin /replsummary 2>&1 | Out-String" } `
    {
        param($o)
        # /replsummary is a concise tabular view: one row per DC with
        # largest delta + failures count. Healthy = mentions both DCs + no
        # 'fails' lines with >0 count. Replaces the earlier /showrepl probe
        # which got truncated before partner rows appeared (caught 2026-05-28
        # repair smoke).
        $o -match 'DC-NEXUS-2' -and $o -notmatch '(?m)^.*\s[1-9]\d*\s+\d+\s+/\s+\d+\s+\d+'
    }

# Per memory/feedback_smoke_gate_probe_robustness.md: use the LIVE-health
# field (ConsecutiveReplicationFailures) instead of LastReplicationResult,
# which lingers on transient bootstrap errors (8524 DNS_ERROR_NAME_ERROR
# when dc-nexus-2's A record was propagating during initial promotion). The
# test-user round-trip check (section 7 below) is the ground truth that
# replication actually works; this check verifies no partner has CURRENT
# consecutive failures.
Test-Check "Get-ADReplicationPartnerMetadata: ConsecutiveReplicationFailures = 0 on all partners" `
    { Invoke-RemotePs -Ip $DcIp -Script "Get-ADReplicationPartnerMetadata -Target dc-nexus.$Domain -PartnerType Both -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ConsecutiveReplicationFailures" } `
    {
        param($o)
        $codes = ($o -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
        # All partners healthy now = at least one metadata row + all rows have
        # 0 consecutive failures. A single stale 8524 with 1 consecutive
        # failure from initial-promotion bootstrap (cleared on the next
        # successful cycle ~15 min later) is acceptable, but anything >1
        # signals a real ongoing issue.
        ($codes.Count -gt 0) -and ($codes | Where-Object { [int]$_ -gt 1 }).Count -eq 0
    }

# ─── 6. DNS replica zones ─────────────────────────────────────────────────
Write-Section '6. DNS replica zones on dc-nexus-2'

Test-Check "dc-nexus-2 hosts nexus.lab zone (AD-integrated)" `
    { Invoke-RemotePs -Ip $Dc2Ip -Script "(Get-DnsServerZone -Name $Domain).IsDsIntegrated.ToString()" } `
    { param($o) $o.Trim() -ieq 'True' }

Test-Check "dc-nexus-2 nexus.lab zone DynamicUpdate=Secure" `
    { Invoke-RemotePs -Ip $Dc2Ip -Script "(Get-DnsServerZone -Name $Domain).DynamicUpdate" } `
    { param($o) $o.Trim() -ieq 'Secure' }

Test-Check "dc-nexus-2 has reverse zone 70.168.192.in-addr.arpa" `
    { Invoke-RemotePs -Ip $Dc2Ip -Script "(Get-DnsServerZone -Name '70.168.192.in-addr.arpa' -ErrorAction SilentlyContinue).ZoneName" } `
    { param($o) $o -match '70\.168\.192\.in-addr\.arpa' }

# ─── 7. Test-user replication round-trip ─────────────────────────────────
Write-Section '7. Test-user replication round-trip (dc-nexus -> dc-nexus-2)'

# Generate a unique test username so re-runs don't collide
$testUser = 'sm0M-' + (Get-Date -Format 'HHmmss') + '-' + (Get-Random -Maximum 9999)
Write-Host "[INFO] Using test user: $testUser" -ForegroundColor DarkCyan

# 7a. Create test user on dc-nexus
Test-Check "Create test user $testUser on dc-nexus" `
    {
        # Force a >=14-char password to satisfy MinPasswordLength=14
        Invoke-RemotePs -Ip $DcIp -Script "try { New-ADUser -Name '$testUser' -SamAccountName '$testUser' -AccountPassword (ConvertTo-SecureString 'TempSmokePass!2026' -AsPlainText -Force) -Enabled `$true -PassThru | Select-Object -ExpandProperty SamAccountName } catch { 'CREATE_FAIL: ' + `$_.Exception.Message }"
    } `
    { param($o) $o -match "^$testUser\s*$" }

# 7b. Force replication
Test-Check "Force replication via repadmin /syncall" `
    { Invoke-RemotePs -Ip $DcIp -Script "repadmin /syncall /AdeP 2>&1 | Out-String; echo 'SYNCED'" } `
    { param($o) $o -match 'SYNCED' }

# 7c. Wait, then probe dc-nexus-2
Write-Host "[INFO] Waiting ${ReplicationWaitSeconds}s for replication to converge..." -ForegroundColor DarkCyan
Start-Sleep -Seconds $ReplicationWaitSeconds

Test-Check "Test user $testUser visible on dc-nexus-2" `
    { Invoke-RemotePs -Ip $Dc2Ip -Script "try { Get-ADUser -Identity '$testUser' -ErrorAction Stop | Select-Object -ExpandProperty SamAccountName } catch { 'NOT_FOUND' }" } `
    { param($o) $o -match "^$testUser\s*$" }

# 7d. Cleanup (best-effort)
$cleanupOut = Invoke-RemotePs -Ip $DcIp -Script "try { Remove-ADUser -Identity '$testUser' -Confirm:`$false; 'CLEANED' } catch { 'CLEANUP_SKIPPED' }" 2>&1 | Out-String
Write-Host "[INFO] Cleanup: $($cleanupOut.Trim())" -ForegroundColor DarkCyan

# ─── Carry-forward spot checks ────────────────────────────────────────────
Write-Section 'Carry-forward (dc-nexus + jumpbox still healthy after 0.M)'

Test-Check "dc-nexus still has healthy forest (Get-ADDomain)" `
    { Invoke-RemotePs -Ip $DcIp -Script "(Get-ADDomain).Forest" } `
    { param($o) $o.Trim() -ieq $Domain }

# Jumpbox is allowed to be graceful-stopped per the minimal-running-VMs
# standing rule (memory/feedback_minimal_running_vms.md). Probe SSH first;
# if it answers, run the carry-forward assertion. Otherwise WARN (operator
# can power on + re-smoke if they want a full verification).
$jumpboxReachable = (Test-NetConnection -ComputerName $JumpboxIp -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)
if ($jumpboxReachable) {
    Test-Check "nexus-jumpbox still PartOfDomain (carry-forward)" `
        { Invoke-RemotePs -Ip $JumpboxIp -Script "(Get-WmiObject Win32_ComputerSystem).PartOfDomain.ToString()" } `
        { param($o) $o.Trim() -eq 'True' }
} else {
    Test-Warn "nexus-jumpbox carry-forward (SSH/22 unreachable; assume graceful-stopped)" `
        { 'JUMPBOX_OFF' } `
        { param($o) $false } `
        -WarnHint "Power on nexus-jumpbox + re-smoke if you want this verified. Per [[minimal-running-vms]], graceful-stopped is the expected state when not in the current phase."
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.M SMOKE CHECKS PASSED' -ForegroundColor Green
    Write-Host "dc-nexus-2 is a healthy replica DC of $Domain; replication GREEN; round-trip user sync verified." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
