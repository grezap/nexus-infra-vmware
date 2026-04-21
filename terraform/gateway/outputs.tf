output "vm_id" {
  description = "VMware Workstation VM ID of nexus-gateway."
  value       = vmworkstation_vm.nexus_gateway.id
}

output "vm_path" {
  description = "Filesystem path of the VMX."
  value       = "${var.vm_output_dir}/nexus-gateway.vmx"
}

output "gateway_ip_vmnet11" {
  description = "Lab gateway IP on VMnet11."
  value       = "192.168.70.1"
}

output "gateway_ip_vmnet10" {
  description = "Backplane IP on VMnet10."
  value       = "192.168.10.1"
}

output "next_step" {
  value = <<-EOT

    ✅ nexus-gateway is deployed.

    Verify from the Windows host:
      Test-NetConnection 192.168.70.1 -Port 53
      Test-NetConnection 192.168.70.1 -Port 9100
      nslookup one.one.one.one 192.168.70.1

    SSH in (build-time credentials; rotated in Phase 0.D):
      ssh nexusadmin@192.168.70.1

    You may now proceed to Phase 0.B.2 — Debian 13 base template.

  EOT
}
