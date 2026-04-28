output "vm_path" {
  description = "Filesystem path of the running smoke-test VM."
  value       = module.win11ent_smoke.vm_path
}

output "mac_address" {
  description = "Pinned MAC -- use this to find the VM's DHCP lease on nexus-gateway."
  value       = module.win11ent_smoke.mac_address
}

output "next_step" {
  value = <<-EOT

    win11ent-smoke is deployed.

    All ssh commands below assume handbook §0.4 SSH client setup is done.
    Otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519` to every ssh.

    Find the VM's DHCP lease on nexus-gateway:
      ssh nexusadmin@192.168.70.1 "grep ${module.win11ent_smoke.mac_address} /var/lib/misc/dnsmasq.leases"

    Or scan VMnet11 from the Windows host:
      200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }

    Probe the VM directly (from the Windows host):
      Test-NetConnection <vm-ip> -Port 22      # OpenSSH
      Test-NetConnection <vm-ip> -Port 9182    # windows_exporter

    SSH into the clone (Windows OpenSSH defaults its remote shell to cmd.exe;
    wrap PowerShell commands in `'powershell -NoProfile -Command "..."'`):
      ssh nexusadmin@<vm-ip> 'powershell -NoProfile -Command "hostname; (Get-Service sshd, windows_exporter).Status"'

    Verify the win11ent client-tooling delta (.NET 10 SDK + Windows Terminal):
      ssh nexusadmin@<vm-ip> 'powershell -NoProfile -Command "dotnet --version; (Get-Command wt.exe).Source"'

    Tear down with:
      make win11ent-smoke-destroy
  EOT
}
