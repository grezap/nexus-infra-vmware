# 02-nexus-network.ps1  --  Windows analog of _shared/ansible/roles/nexus_network
#
# Linux equivalent tasks + their Windows mapping:
#   en*->nic0 (systemd .link)      -> Rename-NetAdapter on the single NIC
#   systemd-networkd DHCP          -> Windows defaults to DHCP on e1000e; no-op
#   chrony client -> 192.168.70.1   -> W32Time service peerlist
#
# The NIC rename is mostly cosmetic on Windows (adapter names aren't as
# ceremony-laden as Linux ens*/enp*), but keeping the 'nic0' label gives us
# consistent metric labels across the fleet when Prometheus + windows_exporter
# report per-interface stats.

$ErrorActionPreference = 'Stop'

# -- 1. NIC rename: whatever the single active Ethernet adapter is -> nic0 --
$adapters = Get-NetAdapter -Physical | Where-Object Status -eq 'Up'
if ($adapters.Count -ne 1) {
    # Packer build runs with a single NAT NIC. If we see more, log + skip
    # instead of failing -- Terraform modules/vm/ will reassign at clone time.
    Write-Host "WARN: expected 1 active physical adapter, found $($adapters.Count). Skipping rename."
}
else {
    $nic = $adapters[0]
    if ($nic.Name -ne 'nic0') {
        Write-Host "Renaming '$($nic.Name)' -> nic0"
        Rename-NetAdapter -Name $nic.Name -NewName 'nic0'
    } else {
        Write-Host "NIC already named nic0 -- skipping rename"
    }
}

# -- 2. W32Time -> chrony-equivalent client pointed at the gateway ----------
# During build we have NAT -> internet, so using the gateway IP (192.168.70.1)
# would fail (not routable from NAT). Point at time.windows.com during build;
# Terraform post-clone or a first-boot script re-points at the gateway once
# VMnet11 is the live NIC.
#
# For the template baseline we still want the *runtime* target to be the
# gateway. So: configure W32Time with the gateway as the manual peer, but
# leave it Disabled during the build; the service will try the peer on first
# post-clone boot and, failing that, fall back to time.windows.com NTP.

Write-Host "Configuring W32Time for runtime: gateway (192.168.70.1) primary, time.windows.com fallback"

# Stop w32time so config takes cleanly
Stop-Service -Name w32time -ErrorAction SilentlyContinue

# Manual peer list -- gateway first, time.windows.com as safety net
w32tm /config /manualpeerlist:"192.168.70.1,0x8 time.windows.com,0x9" /syncfromflags:manual /reliable:no /update | Out-Null

# Make sure service starts automatically at runtime
Set-Service -Name w32time -StartupType Automatic

# -- 3. DNS -- point at the gateway's dnsmasq (192.168.70.1) ----------------
# During build the NAT DHCP supplies its own DNS, which is fine. We bake the
# gateway DNS into the NIC profile via netsh so that when the NIC is re-homed
# to VMnet11 the right resolver is used immediately. systemd-networkd does
# the same thing on the Linux templates via [Network] DNS=.
#
# Use a registry-level setting so it survives the NIC renumber at clone time.
$primaryNic = Get-NetAdapter -Name 'nic0' -ErrorAction SilentlyContinue
if ($primaryNic) {
    # Leave DHCP enabled for IP but override DNS to the gateway.
    Set-DnsClientServerAddress -InterfaceIndex $primaryNic.IfIndex `
        -ServerAddresses @('192.168.70.1') -ErrorAction SilentlyContinue
}

Write-Host "=== 02-nexus-network: OK ==="
