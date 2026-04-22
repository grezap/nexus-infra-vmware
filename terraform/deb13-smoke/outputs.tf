output "vm_path" {
  description = "Filesystem path of the running smoke-test VM."
  value       = module.deb13_smoke.vm_path
}

output "mac_address" {
  description = "Pinned MAC — use this to find the VM's DHCP lease on nexus-gateway."
  value       = module.deb13_smoke.mac_address
}

output "next_step" {
  value = <<-EOT

    ✅ deb13-smoke is deployed.

    The VM will DHCP from nexus-gateway. Find its lease:
      ssh nexusadmin@192.168.70.1 "cat /var/lib/misc/dnsmasq.leases | grep ${module.deb13_smoke.mac_address}"

    Or scan VMnet11 for reachable hosts:
      1..250 | ForEach-Object { Test-Connection -Quiet -Count 1 -TimeoutSeconds 1 "192.168.70.$_" } | Where-Object { $_ }

    Then probe the VM directly:
      Test-NetConnection <vm-ip> -Port 22     # SSH
      Test-NetConnection <vm-ip> -Port 9100   # node_exporter

    Tear down with:
      make deb13-smoke-destroy
  EOT
}
