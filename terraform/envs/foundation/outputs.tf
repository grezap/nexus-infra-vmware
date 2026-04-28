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

output "domain_info" {
  description = "AD DS forest details (only meaningful when enable_dc_promotion=true)."
  value = {
    enabled            = var.enable_dc_promotion
    domain             = var.ad_domain
    netbios            = var.ad_netbios
    dc_hostname        = "dc-nexus"
    dc_fqdn            = var.enable_dc_promotion ? "dc-nexus.${var.ad_domain}" : null
    dc_ip              = "192.168.70.240"
    dns_forward_active = var.enable_gateway_dns_forward
  }
}

output "jumpbox_info" {
  description = "Jumpbox membership details (only meaningful when enable_jumpbox_domain_join=true)."
  value = {
    enabled       = var.enable_jumpbox_domain_join
    hostname      = "nexus-admin-jumpbox"
    fqdn          = var.enable_jumpbox_domain_join ? "nexus-admin-jumpbox.${var.ad_domain}" : null
    ip            = "192.168.70.241"
    domain_member = var.enable_jumpbox_domain_join
  }
}

output "next_step" {
  value = <<-EOT

    foundation env is deployed (dc-nexus + nexus-admin-jumpbox).

    All ssh commands below assume handbook docs/handbook.md §0.4 SSH client
    setup is complete (~/.ssh/config + ssh-agent loaded). If not, prepend
    `-i $HOME\.ssh\nexus_gateway_ed25519` to every ssh invocation.

    Find each VM's DHCP lease on nexus-gateway:
      ssh nexusadmin@192.168.70.1 "grep -iE '${module.dc_nexus.mac_address}|${module.nexus_admin_jumpbox.mac_address}' /var/lib/misc/dnsmasq.leases"

    Or scan VMnet11 from the Windows host:
      200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }

    Probe each VM directly (from the Windows host):
      Test-NetConnection <vm-ip> -Port 22      # OpenSSH
      Test-NetConnection <vm-ip> -Port 9182    # windows_exporter

    SSH into each clone (Windows OpenSSH defaults its remote shell to cmd.exe;
    wrap PowerShell commands in `'powershell -NoProfile -Command "..."'`):
      ssh nexusadmin@<dc-nexus-ip>   'powershell -NoProfile -Command "hostname; (Get-Service sshd).Status"'
      ssh nexusadmin@<jumpbox-ip>    'powershell -NoProfile -Command "hostname; (Get-Service sshd).Status"'

    Verify the AD DS overlay (Phase 0.C.2) -- runs only when var.enable_dc_promotion=true:
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADDomain | Format-List Forest, DomainMode, NetBIOSName"'
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "nltest /dsgetdc:${var.ad_domain}"'
      ssh nexusadmin@192.168.70.1   "dig @127.0.0.1 _ldap._tcp.${var.ad_domain} SRV +short"

    Verify the jumpbox domain-join (Phase 0.C.3) -- runs only when var.enable_jumpbox_domain_join=true:
      ssh nexusadmin@192.168.70.241 'powershell -NoProfile -Command "(Get-WmiObject Win32_ComputerSystem) | Format-List Name, Domain, PartOfDomain, DomainRole"'
      ssh nexusadmin@192.168.70.241 'powershell -NoProfile -Command "nltest /dsgetdc:${var.ad_domain}"'
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADComputer nexus-admin-jumpbox | Format-List Name, DNSHostName, DistinguishedName, Enabled"'

    Selective ops -- per memory/feedback_selective_provisioning.md, every piece of
    foundation is independently controllable. Examples:
      terraform apply -target=module.dc_nexus -auto-approve              # dc-nexus only, no jumpbox
      terraform apply -target=module.nexus_admin_jumpbox -auto-approve   # jumpbox only
      terraform apply -var enable_dc_promotion=false -auto-approve       # bare clones, no AD DS
      terraform apply -target=null_resource.dc_nexus_promote -auto-approve  # iterate on the promotion step
      terraform taint null_resource.dc_nexus_promote && terraform apply -target=null_resource.dc_nexus_promote -auto-approve

    Tear down (whole env):
      make foundation-destroy

    Tear down just the role overlay (keeps the bare clones running):
      terraform apply -var enable_dc_promotion=false -var enable_gateway_dns_forward=false -auto-approve
  EOT
}
