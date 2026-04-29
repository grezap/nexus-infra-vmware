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

output "next_step" {
  value = <<-EOT

    Phase 0.D.1 -- Vault cluster deployed.

    Pre-flight order (do NOT skip):
      1. Foundation env's gateway dnsmasq must have the Vault dhcp-host
         reservations in place BEFORE the Vault clones DHCP. From the repo root:
           pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_dhcp_reservations=true
      2. Vault Packer template must be built:
           cd packer\vault; packer init .; packer build .
      3. THIS env (security):
           pwsh -File scripts\security.ps1 apply

    Smoke gate (Phase 0.D.1):
      pwsh -File scripts\smoke-0.D.1.ps1
      # OR via the wrapper:
      pwsh -File scripts\security.ps1 smoke

    Verify the cluster manually (from the build host):
      $env:VAULT_ADDR = 'https://192.168.70.121:8200'
      $env:VAULT_SKIP_VERIFY = 'true'    # self-signed bootstrap; PKI in 0.D.2
      vault status                       # repeat for .122 and .123
      vault operator raft list-peers     # 3 peers, 1 leader

    Initial creds (after bring-up):
      Root token + 5 unseal keys: ${var.vault_init_keys_file} (mode 0600 on build host)
      Userpass user:   ${var.vault_userpass_user}
      KV-v2 mount:     ${var.vault_kv_mount_path}/
      AppRole name:    ${var.vault_approle_name}

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
      pwsh -File scripts\security.ps1 apply -Vars enable_vault_init=false  # bare clones, no init
      terraform apply -target=module.vault_1                              # one clone only
      terraform apply -target=null_resource.vault_init_leader             # iterate on init step

    Tear down (whole env):
      pwsh -File scripts\security.ps1 destroy
  EOT
}
