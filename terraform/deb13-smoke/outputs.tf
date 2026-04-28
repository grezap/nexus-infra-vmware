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

    All ssh commands below assume handbook §0.4 SSH client setup is done.
    Otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519` to every ssh.

    The VM will DHCP from nexus-gateway. Find its lease:
      ssh nexusadmin@192.168.70.1 "grep ${module.deb13_smoke.mac_address} /var/lib/misc/dnsmasq.leases"

    Or scan VMnet11 from the Windows host:
      1..250 | ForEach-Object { Test-Connection -Quiet -Count 1 -TimeoutSeconds 1 "192.168.70.$_" } | Where-Object { $_ }

    Probe the VM directly:
      Test-NetConnection <vm-ip> -Port 22     # SSH
      Test-NetConnection <vm-ip> -Port 9100   # node_exporter
      ssh nexusadmin@<vm-ip> "uname -a; systemctl is-active prometheus-node-exporter"

    Tear down with:
      make deb13-smoke-destroy
  EOT
}
