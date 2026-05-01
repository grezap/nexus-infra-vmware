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

output "vault_ldap_state" {
  description = "Phase 0.D.3 LDAP overlay state. Only meaningful when var.enable_vault_ldap=true. Cross-env coupling: bindpass is read from var.vault_ad_bind_creds_file at apply time -- foundation env must have written that file via enable_vault_ad_integration=true."
  value = {
    ldap_enabled          = var.enable_vault_ldap
    policies_enabled      = var.enable_vault_ldap && var.enable_vault_ldap_policies
    ldaps_cert_enabled    = var.enable_vault_ldap && var.enable_vault_ldaps_cert
    auth_enabled          = var.enable_vault_ldap && var.enable_vault_ldap_auth
    secret_engine_enabled = var.enable_vault_ldap && var.enable_vault_ldap_secret_engine
    rotate_role_enabled   = var.enable_vault_ldap && var.enable_vault_ldap_rotate_role
    ldap_url              = var.vault_ldap_url
    ldaps_cert_ttl        = var.vault_ldaps_cert_ttl
    user_dn               = var.vault_ldap_user_dn
    group_dn              = var.vault_ldap_group_dn
    userattr              = var.vault_ldap_userattr
    groupattr             = var.vault_ldap_groupattr
    upn_domain            = var.vault_ldap_upn_domain
    userfilter            = var.vault_ldap_userfilter
    bind_creds_file       = var.vault_ad_bind_creds_file
    admin_group           = var.vault_ldap_admin_group
    operator_group        = var.vault_ldap_operator_group
    reader_group          = var.vault_ldap_reader_group
    demo_rotate_account   = var.vault_ldap_demo_rotate_account
    demo_rotation_period  = var.vault_ldap_demo_rotation_period
    policies_defined      = ["nexus-admin", "nexus-operator", "nexus-reader"]
    password_policy_name  = "nexus-ad-rotated"
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

output "vault_kv_foundation_state" {
  description = "Phase 0.D.4 KV foundation seed state -- the AppRole + policy + nexus/foundation/* seeded paths that the foundation env's vault provider data sources consume. Only meaningful when var.enable_vault_kv_foundation_seed=true."
  value = {
    seed_enabled        = var.enable_vault_kv_foundation_seed
    policy_enabled      = var.enable_vault_kv_foundation_seed && var.enable_vault_kv_foundation_policy
    approle_enabled     = var.enable_vault_kv_foundation_seed && var.enable_vault_kv_foundation_approle
    seed_values_enabled = var.enable_vault_kv_foundation_seed && var.enable_vault_kv_foundation_seed_values
    policy_name         = "nexus-foundation-reader"
    approle_name        = "nexus-foundation-reader"
    approle_creds_file  = var.vault_foundation_approle_creds_file
    seeded_paths = [
      "${var.vault_kv_mount_path}/foundation/dc-nexus/dsrm",
      "${var.vault_kv_mount_path}/foundation/dc-nexus/local-administrator",
      "${var.vault_kv_mount_path}/foundation/identity/nexusadmin",
      "${var.vault_kv_mount_path}/foundation/vault/userpass-nexusadmin",
      "${var.vault_kv_mount_path}/foundation/ad/svc-vault-ldap",
      "${var.vault_kv_mount_path}/foundation/ad/svc-vault-smoke",
    ]
  }
}

output "next_step" {
  value = <<-EOT

    Phase 0.D.1 + 0.D.2 + 0.D.3 + 0.D.4 -- Vault cluster + PKI + LDAP +
    foundation cred migration deployed.

    Pre-flight order (do NOT skip):
      1. Foundation env's gateway dnsmasq must have the Vault dhcp-host
         reservations in place AND the AD-side Vault objects (svc accounts +
         groups) created. From the repo root:
           pwsh -File scripts\foundation.ps1 apply ``
             -Vars enable_vault_dhcp_reservations=true,enable_vault_ad_integration=true
      2. Vault Packer template must be built:
           Push-Location packer\vault; packer init .; packer build .; Pop-Location
      3. THIS env (security) -- 0.D.1 cluster + 0.D.2 PKI + 0.D.3 LDAP +
         0.D.4 foundation seed in one apply:
           pwsh -File scripts\security.ps1 apply
      4. Re-apply foundation env with KV-cred reads enabled (0.D.4 consumer
         side; data sources resolve via the AppRole creds JSON written by
         step 3):
           pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_kv_creds=true

    Smoke gate (Phase 0.D.4 -- chains 0.D.3 -> 0.D.2 -> 0.D.1, then layers
    KV-foundation-seed + AppRole-token-policy checks):
      pwsh -File scripts\security.ps1 smoke
      # Or run an earlier phase explicitly:
      pwsh -File scripts\security.ps1 smoke -Phase 0.D.3
      pwsh -File scripts\security.ps1 smoke -Phase 0.D.2
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
      AppRole name (cluster bootstrap):  ${var.vault_approle_name}
      AppRole name (foundation reader):  nexus-foundation-reader  (0.D.4)
      Root CA bundle:  ${var.vault_pki_ca_bundle_path}  (drop VAULT_SKIP_VERIFY; set VAULT_CACERT here)
      LDAP bind cred:  ${var.vault_ad_bind_creds_file}  (binddn + bindpass + smoke creds; mode 0600 on build host -- legacy 0.D.3 artifact, vestigial after 0.D.4 close-out)
      AppRole creds:   ${var.vault_foundation_approle_creds_file}  (0.D.4 -- foundation env's vault provider auth; mode 0600 on build host)

    Phase 0.D.4 -- foundation cred migration (KV-backed reads):
      vault kv get nexus/foundation/dc-nexus/dsrm                  # DSRM pwd
      vault kv get nexus/foundation/dc-nexus/local-administrator   # local Administrator pwd
      vault kv get nexus/foundation/identity/nexusadmin            # nexusadmin AD user pwd
      vault kv get nexus/foundation/vault/userpass-nexusadmin      # vault userpass pwd
      vault kv get nexus/foundation/ad/svc-vault-ldap              # bind cred (Vault auth/ldap)
      vault kv get nexus/foundation/ad/svc-vault-smoke             # smoke probe cred
      # Acceptance criterion (per MASTER-PLAN.md Phase 0.D goal): kv get returns.

    LDAP login (Phase 0.D.3, LDAPS):
      vault login -method=ldap -username=nexusadmin
      # Member of ${var.vault_ldap_admin_group} -> nexus-admin policy (full sudo)
      # Bind goes over ${var.vault_ldap_url} ; cert chain is the PKI root bundle.

    Demo rotate-role (Phase 0.D.3, ON by default):
      vault read ldap/static-cred/${var.vault_ldap_demo_rotate_account}
      # Vault owns the AD password from first apply; rotates every
      # ${var.vault_ldap_demo_rotation_period} via the nexus-ad-rotated
      # password policy. Force-rotate on demand:
      #   vault write -force ldap/rotate-role/${var.vault_ldap_demo_rotate_account}

    Why LDAPS (and not plain LDAP/389):
      Plain LDAP simple bind fails wholesale in this AD environment with
      "Strong Auth Required" regardless of LDAPServerIntegrity (tested 2/1/0;
      all fail). LDAPS pulled forward from 0.D.5 to 0.D.3 -- the
      vault_ldaps_cert overlay issues a leaf cert from pki_int/ for
      dc-nexus.nexus.lab, installs it in dc-nexus's LocalMachine\My store,
      restarts NTDS, and AD then serves LDAPS on TCP/636. Vault auth/ldap
      and secrets/ldap both bind via ${var.vault_ldap_url} with the PKI
      root CA bundle inline as the certificate trust anchor.

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
