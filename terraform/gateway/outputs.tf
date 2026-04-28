output "vm_path" {
  description = "Filesystem path of the running VM's .vmx."
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

    SSH in (assumes handbook §0.4 client setup is done; otherwise prepend
    `-i $HOME\.ssh\nexus_gateway_ed25519`):
      ssh nexusadmin@192.168.70.1

    Build-time credentials inherited from the Packer template; rotated in Phase 0.D.

    You may now proceed to Phase 0.B.2 — Debian 13 base template.

  EOT
}
