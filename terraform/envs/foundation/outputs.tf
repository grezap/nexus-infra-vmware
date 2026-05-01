output "vm_paths" {
  description = "Filesystem paths of each foundation VM's running .vmx, keyed by short name."
  value = {
    dc-nexus      = module.dc_nexus.vm_path
    nexus-jumpbox = module.nexus_admin_jumpbox.vm_path
  }
}

output "mac_addresses" {
  description = "Pinned MAC per VM -- use these to find DHCP leases on nexus-gateway."
  value = {
    dc-nexus      = module.dc_nexus.mac_address
    nexus-jumpbox = module.nexus_admin_jumpbox.mac_address
  }
}

output "domain_info" {
  description = "AD DS forest details (only meaningful when enable_dc_promotion=true). Includes hardening_state showing which Phase 0.C.4 overlays are active."
  value = {
    enabled            = var.enable_dc_promotion
    domain             = var.ad_domain
    netbios            = var.ad_netbios
    dc_hostname        = "dc-nexus"
    dc_fqdn            = var.enable_dc_promotion ? "dc-nexus.${var.ad_domain}" : null
    dc_ip              = "192.168.70.240"
    dns_forward_active = var.enable_gateway_dns_forward
    hardening_state = {
      ous_enabled                = var.enable_dc_ous
      password_policy_enabled    = var.enable_dc_password_policy
      reverse_dns_enabled        = var.enable_dc_reverse_dns
      time_authoritative_enabled = var.enable_dc_time_authoritative
      password_policy_summary = var.enable_dc_password_policy ? {
        min_length         = var.dc_password_min_length
        lockout_threshold  = var.dc_lockout_threshold
        lockout_duration_m = var.dc_lockout_duration_minutes
        max_age_days       = var.dc_max_password_age_days
        min_age_days       = var.dc_min_password_age_days
        history_count      = var.dc_password_history_count
      } : null
      time_peers = var.enable_dc_time_authoritative ? var.dc_time_external_peers : null
    }
  }
}

output "jumpbox_info" {
  description = "Jumpbox membership details (only meaningful when enable_jumpbox_domain_join=true)."
  value = {
    enabled       = var.enable_jumpbox_domain_join
    hostname      = "nexus-jumpbox"
    fqdn          = var.enable_jumpbox_domain_join ? "nexus-jumpbox.${var.ad_domain}" : null
    ip            = "192.168.70.241"
    domain_member = var.enable_jumpbox_domain_join
  }
}

output "vault_ad_state" {
  description = "Phase 0.D.3 AD-side state -- AD service accounts + groups created for Vault LDAP integration. envs/security reads var.vault_ad_bind_creds_file at apply time."
  value = {
    ad_integration_enabled = var.enable_vault_ad_integration
    bind_account_enabled   = var.enable_vault_ad_integration && var.enable_vault_ad_bind_account
    groups_enabled         = var.enable_vault_ad_integration && var.enable_vault_ad_groups
    demo_account_enabled   = var.enable_vault_ad_integration && var.enable_vault_ad_demo_rotated_account
    smoke_account_enabled  = var.enable_vault_ad_integration && var.enable_vault_ad_smoke_account
    bind_account_name      = var.vault_ad_bind_account_name
    smoke_account_name     = var.vault_ad_smoke_account_name
    demo_account_name      = var.vault_ad_demo_rotated_account_name
    group_admins           = var.vault_ad_group_admins
    group_operators        = var.vault_ad_group_operators
    group_readers          = var.vault_ad_group_readers
    bind_creds_file        = var.vault_ad_bind_creds_file
    ldap_url               = "ldap://192.168.70.240:389"
    ldap_signing_relaxed   = var.enable_dc_ldap_signing_relaxed
    ldap_server_integrity  = var.enable_dc_ldap_signing_relaxed ? var.dc_ldap_server_integrity : 2
  }
}

output "bootstrap_creds_rotation_state" {
  description = "Phase 0.D.5 KV -> AD rotation overlay state. Only meaningful when var.enable_dc_rotate_bootstrap_creds=true (default true). Hash changes when any of dsrm/admin/nexusadmin in Vault KV changes."
  value = {
    rotation_enabled      = var.enable_dc_rotate_bootstrap_creds
    requires_kv_creds     = var.enable_vault_kv_creds
    requires_dc_promotion = var.enable_dc_promotion
    rotated_identities    = ["DSRM (via ntdsutil)", "Administrator (via Set-ADAccountPassword)", "nexusadmin (via Set-ADAccountPassword)"]
    rotation_trigger_paths = var.enable_vault_kv_creds ? [
      "${var.vault_kv_mount_path}/foundation/dc-nexus/dsrm",
      "${var.vault_kv_mount_path}/foundation/dc-nexus/local-administrator",
      "${var.vault_kv_mount_path}/foundation/identity/nexusadmin",
    ] : []
  }
}

output "vault_kv_creds_state" {
  description = "Phase 0.D.4 KV-backed bootstrap creds state. Only meaningful when var.enable_vault_kv_creds=true (default false during 0.D.4 development; flips to true at 0.D.4 close-out)."
  value = {
    kv_creds_enabled   = var.enable_vault_kv_creds
    kv_ad_writeback    = var.enable_vault_kv_ad_writeback
    kv_mount_path      = var.vault_kv_mount_path
    approle_creds_file = var.vault_foundation_approle_creds_file
    ca_bundle_path     = var.vault_ca_bundle_path
    consumed_paths = var.enable_vault_kv_creds ? [
      "${var.vault_kv_mount_path}/foundation/dc-nexus/dsrm",
      "${var.vault_kv_mount_path}/foundation/dc-nexus/local-administrator",
      "${var.vault_kv_mount_path}/foundation/identity/nexusadmin",
    ] : []
    written_paths = var.enable_vault_ad_integration && var.enable_vault_kv_ad_writeback ? [
      "${var.vault_kv_mount_path}/foundation/ad/${var.vault_ad_bind_account_name}",
      "${var.vault_kv_mount_path}/foundation/ad/${var.vault_ad_smoke_account_name}",
    ] : []
  }
}

output "next_step" {
  value = <<-EOT

    foundation env is deployed (dc-nexus + nexus-jumpbox).

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
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADComputer nexus-jumpbox | Format-List Name, DNSHostName, DistinguishedName, Enabled"'

    Verify the AD DS hardening overlays (Phase 0.C.4) -- toggleable per overlay:
      # OU layout + jumpbox move (var.enable_dc_ous)
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADOrganizationalUnit -Filter * | Format-Table Name, DistinguishedName -AutoSize"'
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADComputer nexus-jumpbox | Format-List Name, DistinguishedName"'

      # Default Domain Password Policy (var.enable_dc_password_policy)
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADDefaultDomainPasswordPolicy | Format-List MinPasswordLength, LockoutThreshold, LockoutDuration, LockoutObservationWindow, MaxPasswordAge, MinPasswordAge, PasswordHistoryCount, ComplexityEnabled"'

      # Reverse DNS zone + PTR records (var.enable_dc_reverse_dns)
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-DnsServerZone -Name 70.168.192.in-addr.arpa | Format-List ZoneName, ZoneType, IsDsIntegrated, DynamicUpdate"'
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-DnsServerResourceRecord -ZoneName 70.168.192.in-addr.arpa -RRType Ptr | Format-Table HostName, RecordData -AutoSize"'

      # W32Time PDC authoritative config (var.enable_dc_time_authoritative)
      ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "w32tm /query /configuration | Select-String NtpServer; w32tm /query /status"'

    Verify the build-host reachability invariant (per memory/feedback_lab_host_reachability.md)
    -- every fleet VM must remain SSH/22 + RDP/3389 reachable from the build host:
      Test-NetConnection 192.168.70.240 -Port 22    # dc-nexus SSH
      Test-NetConnection 192.168.70.240 -Port 3389  # dc-nexus RDP
      Test-NetConnection 192.168.70.241 -Port 22    # jumpbox SSH
      Test-NetConnection 192.168.70.241 -Port 3389  # jumpbox RDP

    Selective ops -- per memory/feedback_selective_provisioning.md, every piece of
    foundation is independently controllable. Examples:
      terraform apply -target=module.dc_nexus -auto-approve              # dc-nexus only, no jumpbox
      terraform apply -target=module.nexus_admin_jumpbox -auto-approve   # jumpbox only
      terraform apply -var enable_dc_promotion=false -auto-approve       # bare clones, no AD DS
      terraform apply -target=null_resource.dc_nexus_promote -auto-approve  # iterate on the promotion step
      terraform taint null_resource.dc_nexus_promote && terraform apply -target=null_resource.dc_nexus_promote -auto-approve

      # 0.C.4 hardening: each overlay independently togglable
      terraform apply -var enable_dc_ous=false -auto-approve             # skip OU layout
      terraform apply -var enable_dc_password_policy=false -auto-approve # skip password policy
      terraform apply -var enable_dc_reverse_dns=false -auto-approve     # skip reverse DNS zone
      terraform apply -var enable_dc_time_authoritative=false -auto-approve # skip w32tm PDC config
      terraform apply -target=null_resource.dc_ous -auto-approve         # iterate on a single overlay

    Tear down (whole env):
      make foundation-destroy

    Tear down just the role overlay (keeps the bare clones running):
      terraform apply -var enable_dc_promotion=false -var enable_gateway_dns_forward=false -auto-approve

    Tear down just the 0.C.4 hardening (keeps DC + jumpbox + domain join):
      terraform apply -var enable_dc_ous=false -var enable_dc_password_policy=false ``
                      -var enable_dc_reverse_dns=false -var enable_dc_time_authoritative=false -auto-approve

    Phase 0.D.4 -- Vault-KV-backed bootstrap creds (default off; enable
    after security env has applied):
      pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_kv_creds=true
      # Reads dsrm / local-administrator / nexusadmin from nexus/foundation/...
      # via the nexus-foundation-reader AppRole. Provider config in
      # vault-provider.tf reads role-id+secret-id from
      # ${var.vault_foundation_approle_creds_file} (mode 0600 on build host).
      # The CA bundle for TLS verification comes from
      # ${var.vault_ca_bundle_path} (Phase 0.D.2 distribute output).
  EOT
}
