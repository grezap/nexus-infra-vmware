output "vault_paths" {
  description = "Filesystem paths of each Vault VM's running .vmx, keyed by hostname."
  value = var.enable_vault_cluster ? {
    vault-1 = module.vault_1[0].vm_path
    vault-2 = module.vault_2[0].vm_path
    vault-3 = module.vault_3[0].vm_path
  } : {}
}

output "vault_mac_addresses" {
  description = "Canonical per-NIC MAC pinning -- use these to confirm the gateway dnsmasq dhcp-host reservations resolve correctly."
  value = var.enable_vault_cluster ? {
    vault-1 = { primary = module.vault_1[0].mac_address, secondary = var.mac_vault_1_secondary }
    vault-2 = { primary = module.vault_2[0].mac_address, secondary = var.mac_vault_2_secondary }
    vault-3 = { primary = module.vault_3[0].mac_address, secondary = var.mac_vault_3_secondary }
  } : {}
}

output "vault_canonical_ips" {
  description = "Canonical IPs per nexus-platform-plan/docs/infra/vms.yaml lines 55-57."
  value = {
    vault-1 = { vmnet11 = "192.168.70.121", vmnet10 = "192.168.10.121" }
    vault-2 = { vmnet11 = "192.168.70.122", vmnet10 = "192.168.10.122" }
    vault-3 = { vmnet11 = "192.168.70.123", vmnet10 = "192.168.10.123" }
  }
}

output "vault_cluster_state" {
  description = "Phase 0.D.1 cluster bring-up state (only meaningful when enable_vault_init=true)."
  value = {
    init_enabled        = var.enable_vault_init
    cluster_size        = var.enable_vault_cluster ? 3 : 0
    init_keys_file      = var.vault_init_keys_file
    kv_mount_path       = var.vault_kv_mount_path
    userpass_user       = var.vault_userpass_user
    approle_name        = var.vault_approle_name
    leader_api_addr     = "https://192.168.70.121:8200"
    leader_cluster_addr = "https://192.168.10.121:8201"
  }
}

output "vault_pki_state" {
  description = "Phase 0.D.2 PKI overlay state. Only meaningful when var.enable_vault_pki=true. Per-step toggles surface here so operators can confirm which slices ran on this apply."
  value = {
    pki_enabled              = var.enable_vault_pki
    pki_mount_enabled        = var.enable_vault_pki && var.enable_vault_pki_mount
    pki_root_enabled         = var.enable_vault_pki && var.enable_vault_pki_root
    pki_intermediate_enabled = var.enable_vault_pki && var.enable_vault_pki_intermediate
    pki_roles_enabled        = var.enable_vault_pki && var.enable_vault_pki_roles
    pki_rotate_enabled       = var.enable_vault_pki && var.enable_vault_pki_rotate
    pki_distribute_enabled   = var.enable_vault_pki && var.enable_vault_pki_distribute
    pki_cleanup_enabled      = var.enable_vault_pki && var.enable_vault_pki_cleanup_legacy_trust

    pki_mount_path           = "pki/"
    pki_intermediate_mount   = "pki_int/"
    root_ca_common_name      = var.vault_pki_root_common_name
    intermediate_common_name = var.vault_pki_intermediate_common_name
    root_ca_ttl              = var.vault_pki_root_ttl
    intermediate_ttl         = var.vault_pki_intermediate_ttl
    leaf_ttl                 = var.vault_pki_leaf_ttl
    role_name                = var.vault_pki_role_name
    ca_bundle_path           = var.vault_pki_ca_bundle_path
  }
}

output "next_step" {
  value = <<-EOT

    Phase 0.D.1 + 0.D.2 -- Vault cluster + PKI deployed.

    Pre-flight order (do NOT skip):
      1. Foundation env's gateway dnsmasq must have the Vault dhcp-host
         reservations in place BEFORE the Vault clones DHCP. From the repo root:
           pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_dhcp_reservations=true
      2. Vault Packer template must be built:
           cd packer\vault; packer init .; packer build .
      3. THIS env (security) -- both 0.D.1 cluster + 0.D.2 PKI in one apply:
           pwsh -File scripts\security.ps1 apply

    Smoke gate (Phase 0.D.2 -- chains 0.D.1 first, then layers PKI checks):
      pwsh -File scripts\security.ps1 smoke
      # Or run the older 0.D.1-only gate explicitly:
      pwsh -File scripts\security.ps1 smoke -Phase 0.D.1

    Verify the cluster manually (from the build host, post-PKI):
      $env:VAULT_ADDR   = 'https://192.168.70.121:8200'
      $env:VAULT_CACERT = "$HOME\.nexus\vault-ca-bundle.crt"   # 0.D.2 -- replaces VAULT_SKIP_VERIFY
      $env:VAULT_TOKEN  = (Get-Content $HOME\.nexus\vault-init.json | ConvertFrom-Json).root_token
      vault status                       # repeat for .122 and .123
      vault operator raft list-peers     # 3 peers, 1 leader
      vault read pki/cert/ca             # root CA
      vault read pki_int/cert/ca         # intermediate CA

    Initial creds (after bring-up):
      Root token + 5 unseal keys: ${var.vault_init_keys_file} (mode 0600 on build host)
      Userpass user:   ${var.vault_userpass_user}
      KV-v2 mount:     ${var.vault_kv_mount_path}/
      AppRole name:    ${var.vault_approle_name}
      Root CA bundle:  ${var.vault_pki_ca_bundle_path}  (drop VAULT_SKIP_VERIFY; set VAULT_CACERT here)

    Build-host reachability invariant (per memory/feedback_lab_host_reachability.md)
    -- every Vault node must be SSH/22 + 8200 reachable from the build host:
      Test-NetConnection 192.168.70.121 -Port 22
      Test-NetConnection 192.168.70.121 -Port 8200
      Test-NetConnection 192.168.70.122 -Port 22
      Test-NetConnection 192.168.70.122 -Port 8200
      Test-NetConnection 192.168.70.123 -Port 22
      Test-NetConnection 192.168.70.123 -Port 8200

    Selective ops -- per memory/feedback_selective_provisioning.md, every piece is
    independently controllable:
      pwsh -File scripts\security.ps1 apply -Vars enable_vault_init=false           # bare clones, no init or PKI
      pwsh -File scripts\security.ps1 apply -Vars enable_vault_pki=false            # 0.D.1 only, no PKI overlay
      pwsh -File scripts\security.ps1 apply -Vars enable_vault_pki_rotate=false     # PKI mounts but no cert reissue
      terraform apply -target=module.vault_1                                        # one clone only
      terraform apply -target=null_resource.vault_pki_rotate_listener               # iterate on rotation alone

    Tear down (whole env):
      pwsh -File scripts\security.ps1 destroy
  EOT
}
