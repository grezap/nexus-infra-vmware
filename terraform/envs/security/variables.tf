# envs/security -- Phase 0.D.1 Vault cluster variables
#
# Defaults match canon (nexus-platform-plan/docs/infra/vms.yaml lines 55-57)
# except where explicitly flagged as approved deviations.

variable "template_vmx_path" {
  description = "Absolute path to the Packer-built vault template .vmx (Phase 0.D.1 output). All three vault VMs clone from this single template."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/vault/vault.vmx"
}

variable "vm_output_dir_root" {
  description = "Tier directory under which each Vault VM gets its own subdir. Canonical foundation tier per vms.yaml: 01-foundation/."
  type        = string
  default     = "H:/VMS/NexusPlatform/01-foundation"
}

variable "vnet_primary" {
  description = "Primary NIC's VMware network -- VMnet11 service network. DHCP via nexus-gateway dnsmasq with dhcp-host reservations pinning vault-N to canonical .121/.122/.123."
  type        = string
  default     = "VMnet11"
}

variable "vnet_secondary" {
  description = "Secondary NIC's VMware network -- VMnet10 cluster backplane. No DHCP server; static IP assigned by vault-firstboot.sh per hostname mapping."
  type        = string
  default     = "VMnet10"
}

# ─── MAC pins (canonical per docs/handbook.md s 1a tier table) ────────────
# Tier :40-4F = core services; Vault uses :40, :41, :42.
# Convention: fifth byte 0x00 = primary NIC, 0x01 = secondary NIC.

variable "mac_vault_1_primary" {
  description = "vault-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host reservation maps this to 192.168.70.121."
  type        = string
  default     = "00:50:56:3F:00:40"
}

variable "mac_vault_1_secondary" {
  description = "vault-1 secondary NIC MAC (VMnet10). vault-firstboot.sh assigns 192.168.10.121 statically."
  type        = string
  default     = "00:50:56:3F:01:40"
}

variable "mac_vault_2_primary" {
  description = "vault-2 primary NIC MAC (VMnet11). dnsmasq dhcp-host reservation maps this to 192.168.70.122."
  type        = string
  default     = "00:50:56:3F:00:41"
}

variable "mac_vault_2_secondary" {
  description = "vault-2 secondary NIC MAC (VMnet10). vault-firstboot.sh assigns 192.168.10.122 statically."
  type        = string
  default     = "00:50:56:3F:01:41"
}

variable "mac_vault_3_primary" {
  description = "vault-3 primary NIC MAC (VMnet11). dnsmasq dhcp-host reservation maps this to 192.168.70.123."
  type        = string
  default     = "00:50:56:3F:00:42"
}

variable "mac_vault_3_secondary" {
  description = "vault-3 secondary NIC MAC (VMnet10). vault-firstboot.sh assigns 192.168.10.123 statically."
  type        = string
  default     = "00:50:56:3F:01:42"
}

# ─── Selective-provisioning toggles ───────────────────────────────────────

variable "enable_vault_cluster" {
  description = "Toggle: clone the 3 Vault VMs. Default true. Set false to short-circuit the entire env (e.g. iterating on related infrastructure without running the cluster)."
  type        = bool
  default     = true
}

variable "enable_vault_init" {
  description = "Toggle: run the cluster bring-up overlay (init leader, unseal, raft join, KV-v2 mount, auth methods). Default true. Set false to land bare clones only -- useful when iterating on the vault Packer template."
  type        = bool
  default     = true
}

# ─── Vault cluster bring-up parameters ────────────────────────────────────

variable "vault_init_key_shares" {
  description = "vault operator init -key-shares. Default 5 (Vault default)."
  type        = number
  default     = 5
}

variable "vault_init_key_threshold" {
  description = "vault operator init -key-threshold. Default 3 (Vault default)."
  type        = number
  default     = 3
}

variable "vault_init_keys_file" {
  description = "Absolute path on the build host where the init keys + root token JSON gets written. mode 0600. NOT in tfstate (per memory/feedback_master_plan_authority.md scope decision -- pre-Phase-0.E we keep secrets out of state)."
  type        = string
  default     = "$HOME/.nexus/vault-init.json"
}

variable "vault_kv_mount_path" {
  description = "Mount path for the KV-v2 secrets engine. Per MASTER-PLAN.md s 0.D goal (line 145): nexus/* paths."
  type        = string
  default     = "nexus"
}

variable "vault_userpass_user" {
  description = "Initial userpass auth user for human ops."
  type        = string
  default     = "nexusadmin"
}

variable "vault_userpass_password" {
  description = "Initial userpass auth password. Pre-Phase-0.D.4 plaintext default; rotated to a Vault-managed credential in 0.D.4 alongside foundation env's bootstrap creds."
  type        = string
  default     = "NexusVaultOps!1"
  sensitive   = true
}

variable "vault_approle_name" {
  description = "Initial AppRole name (per MASTER-PLAN.md s 0.D goal: AppRole)."
  type        = string
  default     = "nexus-bootstrap"
}

variable "vault_cluster_timeout_minutes" {
  description = "Per-step timeout for cluster bring-up (SSH echo probes, init wait, raft-join wait)."
  type        = number
  default     = 15
}

# Used by the role overlay's SSH commands
variable "vault_node_user" {
  description = "SSH user on each Vault node. Same as deb13's bootstrap user."
  type        = string
  default     = "nexusadmin"
}

# ─── Phase 0.D.2 PKI overlay toggles ─────────────────────────────────────
#
# Per memory/feedback_selective_provisioning.md, every PKI step is
# independently toggle-able. Master toggle var.enable_vault_pki gates the
# whole layer; per-step toggles default true and AND-compose with the master.
#
# Order: mount -> root -> intermediate -> roles -> rotate -> distribute -> cleanup
# All steps depend_on null_resource.vault_post_init (cluster + KV-v2 + auth
# methods must be live before PKI bootstrap runs).

variable "enable_vault_pki" {
  description = "Master toggle: bootstrap Vault PKI (root + intermediate + role + cert reissue + CA distribution + legacy trust cleanup). Default true. Set false to short-circuit the entire 0.D.2 layer (e.g. iterating on the 0.D.1 cluster bring-up alone)."
  type        = bool
  default     = true
}

variable "enable_vault_pki_mount" {
  description = "Toggle: mount PKI (pki/) and intermediate (pki_int/) secrets engines. Idempotent via probe."
  type        = bool
  default     = true
}

variable "enable_vault_pki_root" {
  description = "Toggle: generate the internal root CA at pki/. Idempotent via vault read pki/cert/ca probe."
  type        = bool
  default     = true
}

variable "enable_vault_pki_intermediate" {
  description = "Toggle: generate intermediate CSR at pki_int/, sign via root, set signed cert. Idempotent via vault read pki_int/cert/ca probe."
  type        = bool
  default     = true
}

variable "enable_vault_pki_roles" {
  description = "Toggle: define the vault-server PKI role for issuing listener certs. Idempotent overwrite (vault write semantics are upsert)."
  type        = bool
  default     = true
}

variable "enable_vault_pki_rotate" {
  description = "Toggle: per-node leaf cert issuance + atomic-swap into /etc/vault.d/tls/ + SIGHUP reload. Idempotent via current-cert issuer + days-remaining probe (skips if cert is already PKI-issued and >30d remaining)."
  type        = bool
  default     = true
}

variable "enable_vault_pki_distribute" {
  description = "Toggle: write root CA bundle to build host ($HOME\\.nexus\\vault-ca-bundle.crt) + install on each Vault node's system trust store. Hash-compare idempotent."
  type        = bool
  default     = true
}

variable "enable_vault_pki_cleanup_legacy_trust" {
  description = "Toggle: remove the per-clone /usr/local/share/ca-certificates/vault-leader.crt residue from followers (the 0.D.1 cold-start hack -- distribute step replaces it with the shared root CA, this step removes the stale per-clone cert). File-existence idempotent."
  type        = bool
  default     = true
}

# ─── Phase 0.D.2 PKI parameters ──────────────────────────────────────────

variable "vault_pki_root_common_name" {
  description = "Common Name for the root CA. Per Phase 0.D.2 design (canon-silent on common_name; chosen to identify the lab portfolio root)."
  type        = string
  default     = "NexusPlatform Root CA"
}

variable "vault_pki_intermediate_common_name" {
  description = "Common Name for the intermediate CA. All leaf certs (vault listeners, future templates) chain through this."
  type        = string
  default     = "NexusPlatform Intermediate CA"
}

variable "vault_pki_root_ttl" {
  description = "Root CA TTL. Default 87600h = 10 years -- root signs the intermediate once and is otherwise unused; long-lived per standard PKI design."
  type        = string
  default     = "87600h"
}

variable "vault_pki_intermediate_ttl" {
  description = "Intermediate CA TTL. Default 43800h = 5 years -- long enough to outlast Phase 0.D.* iterations; rotation is a 0.D.5+ concern."
  type        = string
  default     = "43800h"
}

variable "vault_pki_leaf_ttl" {
  description = "Leaf cert TTL for issued vault-server certs. Default 8760h = 1 year. Lab-acceptable cadence (test-enterprise lab; Vault Agent automated renewal lands in 0.D.5 with a shorter TTL)."
  type        = string
  default     = "8760h"
}

variable "vault_pki_role_name" {
  description = "Name of the PKI role used to issue vault listener certs. Per pki_int/issue/<role> URL semantics."
  type        = string
  default     = "vault-server"
}

variable "vault_pki_ca_bundle_path" {
  description = "Absolute path on the build host where the root CA bundle gets distributed. Operator points VAULT_CACERT at this path to drop VAULT_SKIP_VERIFY. Default mirrors vault-init.json under operator-private $HOME/.nexus/."
  type        = string
  default     = "$HOME/.nexus/vault-ca-bundle.crt"
}

# ─── Phase 0.D.3 LDAP overlay toggles ────────────────────────────────────
#
# Order: policies -> auth -> secret-engine -> rotate-role
# All steps depend_on null_resource.vault_pki_distribute_root (PKI must
# be live before LDAP overlays mount; future LDAPS work will share the PKI).
# Each step has its own enable_vault_ldap_<thing> toggle defaulting true,
# AND-composed with the master enable_vault_ldap.
#
# Cross-env coupling: this overlay reads the bind cred JSON written by
# envs/foundation/role-overlay-dc-vault-ad-bind.tf at
# var.vault_ad_bind_creds_file (default $HOME/.nexus/vault-ad-bind.json).
# Foundation must apply with -Vars enable_vault_ad_integration=true BEFORE
# the security env's LDAP overlays will succeed.

variable "enable_vault_ldap" {
  description = "Master toggle: configure Vault auth/ldap + secrets/ldap. Default true. Set false to land cluster + PKI without LDAP integration (e.g. iterating on PKI alone)."
  type        = bool
  default     = true
}

variable "enable_vault_ldap_policies" {
  description = "Toggle: write Vault policies (nexus-admin, nexus-operator, nexus-reader) referenced by LDAP group->policy mappings. Default true. Idempotent overwrite via `vault policy write`."
  type        = bool
  default     = true
}

variable "enable_vault_ldap_auth" {
  description = "Toggle: enable + configure auth/ldap method (URL, binddn, bindpass, userdn/groupdn) and write group->policy mappings. Default true. Reads bindpass from var.vault_ad_bind_creds_file."
  type        = bool
  default     = true
}

variable "enable_vault_ldap_secret_engine" {
  description = "Toggle: enable + configure secrets/ldap engine (the unified AD/OpenLDAP engine, GA in Vault 1.12+ -- replaces deprecated `ad` engine). Used by static rotate-role. Default true."
  type        = bool
  default     = true
}

variable "enable_vault_ldap_rotate_role" {
  description = "Toggle: define the static rotate-role for svc-demo-rotated. Requires LDAPS (handled by enable_vault_ldaps_cert in 0.D.3+ -- pulled forward from 0.D.5 because plain LDAP simple bind fails wholesale in this AD environment). On first apply Vault rotates the AD password to a Vault-managed value; subsequent reads return the current pwd via `vault read ldap/static-cred/<name>`. Default true."
  type        = bool
  default     = true
}

variable "enable_vault_ldaps_cert" {
  description = "Toggle: issue a leaf cert from Vault PKI for dc-nexus.nexus.lab and install it in dc-nexus's LocalMachine\\My cert store, then restart NTDS so AD DS auto-discovers + serves LDAPS on TCP/636. Required for Vault's auth/ldap + secrets/ldap to bind to AD because plain LDAP/389 simple bind fails in this AD env regardless of LDAPServerIntegrity (tested 2/1/0; all fail). Originally 0.D.5 scope; pulled forward to close 0.D.3. Default true."
  type        = bool
  default     = true
}

variable "vault_ldaps_cert_ttl" {
  description = "TTL for the LDAPS cert issued from pki_int/issue/<role> for dc-nexus. Default 8760h = 1 year (matches the rest of the lab leaf-cert convention; renewable via re-apply when <30 days remain)."
  type        = string
  default     = "8760h"
}

variable "vault_ad_bind_creds_file" {
  description = "Absolute path on the build host where envs/foundation/role-overlay-dc-vault-ad-bind.tf wrote the bind credentials JSON. envs/security reads { binddn, bindpass, smoke_username, smoke_password, ldap_url } from this file. Mirrors the foundation env's default."
  type        = string
  default     = "$HOME/.nexus/vault-ad-bind.json"
}

variable "vault_ldap_url" {
  description = "LDAP URL for the Vault auth/ldap + secrets/ldap config. ldaps://192.168.70.240:636 -- LDAPS pulled forward from 0.D.5 to 0.D.3 because plain LDAP/389 simple bind fails wholesale in this AD env. The DC cert is issued from Vault PKI by role-overlay-vault-ldaps-cert.tf and trusted by Vault via the certificate field (which receives the PKI root CA bundle inline)."
  type        = string
  default     = "ldaps://192.168.70.240:636"
}

variable "vault_ldap_user_dn" {
  description = "userdn for Vault's LDAP user-search base. Wide root scope (entire forest tree); userattr scopes the actual lookup."
  type        = string
  default     = "DC=nexus,DC=lab"
}

variable "vault_ldap_group_dn" {
  description = "groupdn for Vault's LDAP group-search base. Wide root scope; Vault filters by group-of-user membership at query time."
  type        = string
  default     = "DC=nexus,DC=lab"
}

variable "vault_ldap_userattr" {
  description = "Vault auth/ldap userattr -- AD attribute used to match the login username. samAccountName is canonical for AD; alternatives are userPrincipalName or uid."
  type        = string
  default     = "samAccountName"
}

variable "vault_ldap_groupattr" {
  description = "Vault auth/ldap groupattr -- AD attribute used as the group name in policy mappings. cn matches the AD security group name; alternatives are sAMAccountName."
  type        = string
  default     = "cn"
}

variable "vault_ldap_upn_domain" {
  description = "Vault auth/ldap upndomain -- the UPN suffix Vault uses to construct the user-bind DN (canonical AD pattern). With this set, Vault binds as `<username>@<upndomain>` directly, which AD handles via userPrincipalName matching -- skipping the separate search-then-rebind flow that fails with `failed to bind as user` on plain LDAP/389 even when the password is correct (Vault's go-ldap re-bind on the same connection trips AD's signing requirement). Set the value to match the AD forest (nexus.lab) so userPrincipalName=<sam>@nexus.lab resolves cleanly. Default 'nexus.lab' matches var.ad_domain in foundation env."
  type        = string
  default     = "nexus.lab"
}

variable "vault_ldap_userfilter" {
  description = "Vault auth/ldap userfilter -- the LDAP filter used when Vault DOES need to search (e.g., group enumeration). AD-canonical filter narrows to user objects only via objectClass=user, avoiding accidental matches against computers, contacts, or other directory objects. The default Vault filter `({{.UserAttr}}={{.Username}})` is generic LDAP and trips on AD-specific edge cases."
  type        = string
  default     = "(&(objectClass=user)(sAMAccountName={{.Username}}))"
}

variable "vault_ldap_admin_group" {
  description = "AD group whose members get the `nexus-admin` Vault policy. Must match the foundation env's var.vault_ad_group_admins."
  type        = string
  default     = "nexus-vault-admins"
}

variable "vault_ldap_operator_group" {
  description = "AD group whose members get the `nexus-operator` Vault policy. Must match the foundation env's var.vault_ad_group_operators."
  type        = string
  default     = "nexus-vault-operators"
}

variable "vault_ldap_reader_group" {
  description = "AD group whose members get the `nexus-reader` Vault policy. Must match the foundation env's var.vault_ad_group_readers."
  type        = string
  default     = "nexus-vault-readers"
}

variable "vault_ldap_demo_rotate_account" {
  description = "samAccountName of the AD account that Vault's secrets/ldap static rotate-role manages. Must match the foundation env's var.vault_ad_demo_rotated_account_name."
  type        = string
  default     = "svc-demo-rotated"
}

variable "vault_ldap_demo_rotation_period" {
  description = "Static rotate-role rotation_period for svc-demo-rotated. Format: Vault duration string (e.g. '24h', '7d'). Default 24h -- Vault rotates the AD password daily."
  type        = string
  default     = "24h"
}

# ─── Phase 0.D.4 — foundation cred migration into Vault KV ───────────────
#
# Three new overlays land here (policy, approle, seed) so the foundation
# env can drop its plaintext bootstrap credentials and read them from
# `nexus/foundation/...` via vault_kv_secret_v2 data sources instead.
#
# Order: policy -> approle -> seed (one-time, sticky-write).
# Master toggle var.enable_vault_kv_foundation_seed gates the whole layer;
# per-step toggles default true and AND-compose with the master.
# All steps depend_on null_resource.vault_post_init.
#
# Cross-env coupling:
#   - The seed overlay reads $HOME/.nexus/vault-ad-bind.json (legacy 0.D.3
#     output) on the build host and migrates its contents into
#     nexus/foundation/ad/svc-vault-ldap + nexus/foundation/ad/svc-vault-smoke.
#     If the file is absent (greenfield without 0.D.3-style ad-integration),
#     those two paths are skipped -- foundation env's bind/smoke overlays
#     write them direct-to-KV at create time once 0.D.4 lands.
#   - The approle overlay writes
#     $HOME/.nexus/vault-foundation-approle.json (mode 0600 equivalent via
#     icacls) which the foundation env's `provider "vault"` block reads at
#     plan/apply time.
#
# Seed values mirror foundation env defaults exactly. Override here only
# if you want different starting passwords than the foundation defaults.
# Once seeded, ROTATE via Vault (vault kv put nexus/foundation/...) -- the
# seed step will not overwrite a populated path.

variable "enable_vault_kv_foundation_seed" {
  description = "Master toggle: bootstrap nexus-foundation-reader policy + AppRole + seed plaintext defaults at nexus/foundation/...  Default true. Set false to short-circuit the entire 0.D.4 layer (e.g. iterating on 0.D.1-3 alone)."
  type        = bool
  default     = true
}

variable "enable_vault_kv_foundation_policy" {
  description = "Toggle: write the nexus-foundation-reader policy (read on nexus/data/foundation/*, write on nexus/data/foundation/ad/* only). Default true. Idempotent overwrite via `vault policy write`."
  type        = bool
  default     = true
}

variable "enable_vault_kv_foundation_approle" {
  description = "Toggle: define AppRole nexus-foundation-reader and persist role-id+secret-id into vault-foundation-approle.json on the build host. Default true. role-id is stable across re-applies; secret-id is regenerated on every apply."
  type        = bool
  default     = true
}

variable "enable_vault_kv_foundation_seed_values" {
  description = "Toggle: one-time seed of plaintext defaults + JSON migration into nexus/foundation/...  Default true. Sticky writes -- never overwrites a populated path. Set false to skip seeding (e.g. when re-applying a security env that already seeded; this also avoids re-shipping plaintext defaults through SSH if you've rotated everything in Vault already)."
  type        = bool
  default     = true
}

variable "vault_foundation_approle_creds_file" {
  description = "Absolute path on the build host where the AppRole role-id + secret-id JSON gets written. mode 0600 via icacls. Mirrors vault-init.json under operator-private $HOME/.nexus/. The foundation env's `provider \"vault\"` block reads this file at plan/apply time."
  type        = string
  default     = "$HOME/.nexus/vault-foundation-approle.json"
}

variable "foundation_seed_dsrm_password" {
  description = "Seed value for nexus/foundation/dc-nexus/dsrm at password. Default matches the foundation env's var.dsrm_password default exactly (NexusDSRM!1) so a steady-state lab seeds back to the same value after a destroy+apply cycle. Override to seed a different starting pwd; rotate-after-seed via `vault kv put nexus/foundation/dc-nexus/dsrm password=...`."
  type        = string
  default     = "NexusDSRM!1"
  sensitive   = true
}

variable "foundation_seed_local_administrator_password" {
  description = "Seed value for nexus/foundation/dc-nexus/local-administrator at password. Default matches foundation env's var.local_administrator_password default (NexusAdmin!1)."
  type        = string
  default     = "NexusAdmin!1"
  sensitive   = true
}

variable "foundation_seed_nexusadmin_password" {
  description = "Seed value for nexus/foundation/identity/nexusadmin at password. Default matches foundation env's var.nexusadmin_password default (NexusPackerBuild!1) -- mirrors the build-time bootstrap pwd that ws2025-desktop's Packer template bakes in."
  type        = string
  default     = "NexusPackerBuild!1"
  sensitive   = true
}
