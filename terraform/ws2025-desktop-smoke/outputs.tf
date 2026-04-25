output "vm_path" {
  description = "Filesystem path of the running smoke-test VM."
  value       = module.ws2025_desktop_smoke.vm_path
}

output "mac_address" {
  description = "Pinned MAC -- use this to find the VM's DHCP lease on nexus-gateway."
  value       = module.ws2025_desktop_smoke.mac_address
}

output "next_step" {
  value = <<-EOT

    ✅ ws2025-desktop-smoke is deployed.

    Find the VM's DHCP lease on nexus-gateway:
      ssh nexusadmin@192.168.70.1 "grep ${module.ws2025_desktop_smoke.mac_address} /var/lib/misc/dnsmasq.leases"

    Or scan VMnet11 for reachable hosts:
      200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }

    Probe directly (from the Windows host):
      Test-NetConnection <vm-ip> -Port 22      # OpenSSH
      Test-NetConnection <vm-ip> -Port 9182    # windows_exporter
      ssh nexusadmin@<vm-ip>                    # key-only, no password

    Verify the Desktop Experience delta (RSAT/GPMC/DNS tools):
      ssh nexusadmin@192.168.70.1 ssh nexusadmin@<vm-ip> `
        "Get-WindowsFeature RSAT-AD-Tools, RSAT-DNS-Server, RSAT-DHCP, GPMC | ft Name, InstallState"

    Tear down with:
      make ws2025-desktop-smoke-destroy
  EOT
}
