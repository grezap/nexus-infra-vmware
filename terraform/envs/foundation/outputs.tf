output "vm_paths" {
  description = "Filesystem paths of each foundation VM's running .vmx, keyed by short name."
  value = {
    dc-nexus            = module.dc_nexus.vm_path
    nexus-admin-jumpbox = module.nexus_admin_jumpbox.vm_path
  }
}

output "mac_addresses" {
  description = "Pinned MAC per VM -- use these to find DHCP leases on nexus-gateway."
  value = {
    dc-nexus            = module.dc_nexus.mac_address
    nexus-admin-jumpbox = module.nexus_admin_jumpbox.mac_address
  }
}

output "next_step" {
  value = <<-EOT

    foundation env is deployed (dc-nexus + nexus-admin-jumpbox).

    Find each VM's DHCP lease on nexus-gateway:
      ssh nexusadmin@192.168.70.1 "grep -iE '${module.dc_nexus.mac_address}|${module.nexus_admin_jumpbox.mac_address}' /var/lib/misc/dnsmasq.leases"

    Or scan VMnet11 for reachable hosts:
      200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }

    Probe each VM directly (from the Windows host):
      Test-NetConnection <vm-ip> -Port 22      # OpenSSH
      Test-NetConnection <vm-ip> -Port 9182    # windows_exporter
      ssh nexusadmin@<vm-ip>                    # key-only, no password

    Verify dc-nexus is ready for AD DS promotion (RSAT shipped by ws2025-desktop):
      ssh nexusadmin@192.168.70.1 ssh nexusadmin@<dc-nexus-ip> `
        "Get-WindowsFeature AD-Domain-Services, RSAT-AD-Tools, GPMC | ft Name, InstallState"

    Verify nexus-admin-jumpbox has the operator toolset:
      ssh nexusadmin@192.168.70.1 ssh nexusadmin@<jumpbox-ip> `
        "Get-WindowsFeature RSAT-AD-Tools, RSAT-DNS-Server, RSAT-DHCP, GPMC | ft Name, InstallState"

    Tear down with:
      make foundation-destroy
  EOT
}
