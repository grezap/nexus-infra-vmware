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
  description = "Leaf cert TTL for issued vault-server certs. Default 2160h = 90 days at 0.D.5 close-out (was 8760h = 1 year through 0.D.4). Quarterly rotation cadence aligns with operator review windows; existing rotate-listener probe (`days-remaining > 30`) still works at this TTL since the 30-day threshold is < 60 of the 90-day window. Will tighten to 30d in a later phase once Vault Agent automated renewal proves stable across multiple cycles."
  type        = string
  default     = "2160h"
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
  description = "TTL for the LDAPS cert issued from pki_int/issue/<role> for dc-nexus. Default 2160h = 90 days at 0.D.5 close-out (was 8760h = 1 year through 0.D.4). Matches vault_pki_leaf_ttl. The vault_ldaps_cert overlay's renewal-on-re-apply pattern handles the shorter cadence; smoke gate's `>=30 days remaining` predicate stays valid (30d < 60d threshold within a 90d window)."
  type        = string
  default     = "2160h"
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
  description = "Seed value for nexus/foundation/dc-nexus/dsrm at password. Default matches the foundation env's var.dsrm_password default (NexusDSRMBootstrap!2026, >=14 chars per 0.D.5 MinPasswordLength=14 policy) so a steady-state lab seeds back to the same value after a destroy+apply cycle. Override to seed a different starting pwd; rotate-after-seed via `vault kv put nexus/foundation/dc-nexus/dsrm password=$(openssl rand -base64 24)` then re-apply foundation env (the dc_rotate_bootstrap_creds overlay pushes the new pwd to AD)."
  type        = string
  default     = "NexusDSRMBootstrap!2026"
  sensitive   = true
}

variable "foundation_seed_local_administrator_password" {
  description = "Seed value for nexus/foundation/dc-nexus/local-administrator at password. Default matches foundation env's var.local_administrator_password default (NexusLocalAdminBootstrap!2026, >=14 chars per 0.D.5 MinPasswordLength=14 policy)."
  type        = string
  default     = "NexusLocalAdminBootstrap!2026"
  sensitive   = true
}

variable "foundation_seed_nexusadmin_password" {
  description = "Seed value for nexus/foundation/identity/nexusadmin at password. Default matches foundation env's var.nexusadmin_password default (NexusPackerBuild!1) -- mirrors the build-time bootstrap pwd that ws2025-desktop's Packer template bakes in."
  type        = string
  default     = "NexusPackerBuild!1"
  sensitive   = true
}

# ─── Phase 0.D.5 — Vault Agent AppRoles (dc-nexus + nexus-jumpbox) ───────
#
# Two AppRoles, one per Windows host that runs Vault Agent. Each AppRole
# has a NARROW policy granting read on only the KV paths that host
# actually consumes. Role-id + secret-id JSON sidecars get written to
# the build host (operator-private $HOME/.nexus/) and the foundation
# env's Vault Agent install overlay copies them onto the target host
# at apply time.
#
# Order: agent_policies -> agent_approles -> (foundation env consumes)
# All steps depend_on null_resource.vault_post_init.

variable "enable_vault_agent_setup" {
  description = "Master toggle: scaffold Vault Agent infrastructure (policies + AppRoles + JSON sidecars). Default true. Set false to skip 0.D.5.4 entirely."
  type        = bool
  default     = true
}

variable "enable_vault_agent_policies" {
  description = "Toggle: write the two narrow Vault policies (nexus-agent-dc-nexus + nexus-agent-nexus-jumpbox). Default true. Idempotent overwrite."
  type        = bool
  default     = true
}

variable "enable_vault_agent_approles" {
  description = "Toggle: define the two AppRoles + persist role-id+secret-id JSON sidecars on the build host. Default true. role-id is stable; secret-id is regenerated per security apply."
  type        = bool
  default     = true
}

variable "vault_agent_dc_nexus_creds_file" {
  description = "Absolute path on the build host where the dc-nexus Vault Agent's role-id + secret-id JSON gets written. mode 0600 via icacls. Foundation env's Vault Agent install overlay reads this + scp's role-id/secret-id files to dc-nexus."
  type        = string
  default     = "$HOME/.nexus/vault-agent-dc-nexus.json"
}

variable "vault_agent_nexus_jumpbox_creds_file" {
  description = "Absolute path on the build host where the nexus-jumpbox Vault Agent's role-id + secret-id JSON gets written. mode 0600 via icacls."
  type        = string
  default     = "$HOME/.nexus/vault-agent-nexus-jumpbox.json"
}

# ─── Phase 0.D.5.5 — Transit auto-unseal (vault-transit + cluster reconfig) ───
#
# vault-transit is a single-node Vault VM whose only job is hosting a
# transit secrets engine + a seal key. The 3-node cluster (vault-1/2/3)
# uses transit-seal mode with vault-transit as the seal target -- when
# they boot, they auto-unseal by calling transit/decrypt on vault-transit
# (no manual unseal keys needed).
#
# Greenfield bring-up sequence (per Greg's 0.D.5.5 briefing approval --
# in-place migration rejected for lab; greenfield is simpler/safer):
#
#   1. operator: pwsh -File scripts\security.ps1 destroy   (destroys 3-node cluster)
#   2. operator: rebuild Vault Packer template (firstboot v2 + vault.service v2)
#   3. operator: pwsh -File scripts\security.ps1 apply
#        - vault-transit comes up first (shamir mode; manual init+unseal once)
#        - transit engine enabled, key created, token issued, JSON sidecar persisted
#        - vault-1/2/3 come up; TF delivers seal-transit.hcl to each
#        - cluster init with -recovery-shares (NOT -key-shares); transit auto-unseal works
#   4. operator: pwsh -File scripts\foundation.ps1 apply   (re-seeds KV-dependent state)
#   5. operator: pwsh -File scripts\security.ps1 smoke     (chained 0.D.1-5 should green)
#
# vault-transit topology:
#   - VMnet11 service .124 (next free after vault-3=.123)
#   - VMnet10 backplane 192.168.10.124 (single-node; backplane unused for cluster
#     traffic but kept for symmetry + future scale-out)
#   - MAC 00:50:56:3F:00:43 (next free in :40-4F range)
#   - Same Packer template as cluster (firstboot's hostname-IP map covers .124)
#   - file storage backend (per Greg's briefing #2 -- single node, no Raft needed)
#   - own init keys (vault-transit-init.json, mode 0600 on build host)
#   - shamir seal mode (the unseal key custodian itself can't auto-unseal;
#     manual unseal once per reboot of vault-transit OR a 0.D.6+ override
#     using a 4th unseal target)

variable "enable_vault_transit_unseal" {
  description = "Master toggle: bring up vault-transit + reconfigure 3-node cluster to use transit auto-unseal. Default true (flipped from false at 0.D.5.5 greenfield close-out 2026-05-03 per feedback_terraform_partial_apply_destroys_resources.md -- defaults reflect steady state, opt-out is the explicit override). WARNING: switching this from true->false on a running cluster destroys vault-transit; the cluster's data was encrypted with vault-transit's transit key; ANY node restart after that point auto-unseals via a non-existent target and fails. If you actually want to opt out of transit mode, you must greenfield-destroy+rebuild the cluster in shamir mode, not just flip this back."
  type        = bool
  default     = true
}

variable "enable_vault_transit_vm" {
  description = "Toggle: clone vault-transit VM. Default true (gated under enable_vault_transit_unseal). Set false to skip the entire transit layer (e.g. iterating on the 3-node cluster's pre-transit config)."
  type        = bool
  default     = true
}

variable "enable_vault_transit_bringup" {
  description = "Toggle: init vault-transit + enable transit engine + create key + issue cluster auth token + persist JSON sidecar. Default true. Idempotent via vault status / mount probes. Set false to land the bare clone only."
  type        = bool
  default     = true
}

variable "enable_vault_cluster_seal_config" {
  description = "Toggle: deliver /etc/vault.d/seal-transit.hcl to vault-1/2/3 (post-clone, pre-init). Required for transit auto-unseal to work. Default true (gated under enable_vault_transit_unseal)."
  type        = bool
  default     = true
}

# vault-transit clone parameters
variable "mac_vault_transit_primary" {
  description = "vault-transit primary NIC MAC (VMnet11). dnsmasq dhcp-host reservation maps this to 192.168.70.124."
  type        = string
  default     = "00:50:56:3F:00:43"
}

variable "mac_vault_transit_secondary" {
  description = "vault-transit secondary NIC MAC (VMnet10). vault-firstboot.sh assigns 192.168.10.124 statically."
  type        = string
  default     = "00:50:56:3F:01:43"
}

variable "vault_transit_init_keys_file" {
  description = "Absolute path on the build host where vault-transit's init keys + root token JSON gets written. Separate from vault-init.json (different cluster). mode 0600."
  type        = string
  default     = "$HOME/.nexus/vault-transit-init.json"
}

variable "vault_transit_token_file" {
  description = "Absolute path on the build host where vault-transit's cluster-auth token JSON gets written. The 3-node cluster's seal-transit.hcl references this token to call transit/decrypt at unseal time. mode 0600."
  type        = string
  default     = "$HOME/.nexus/vault-transit-token.json"
}

variable "vault_transit_key_name" {
  description = "Name of the transit key in vault-transit that the 3-node cluster uses to wrap its seal data. Default 'nexus-cluster-unseal'."
  type        = string
  default     = "nexus-cluster-unseal"
}

# ─── Phase 0.E.2 — Consul harden setup (PKI + KV seed + 6 swarm AppRoles) ──
# These variables wire in the PKI role + Vault Agent infrastructure that
# Phases 0.E.2.1 (gossip encrypt), 0.E.2.2 (TLS), and 0.E.2.3 (ACL) all
# consume. The actual rendering happens swarm-nomad-side; this env owns
# the Vault-side state.

variable "enable_swarm_pki" {
  description = "Toggle: create the pki_int/roles/consul-server PKI role used by the 6 swarm-node Vault Agents. Default true."
  type        = bool
  default     = true
}

variable "vault_pki_consul_role_name" {
  description = "Name of the PKI role under pki_int/ for Consul leaf certs. Used by 0.E.2.2 TLS. Default 'consul-server'."
  type        = string
  default     = "consul-server"
}

variable "enable_swarm_secrets_seed" {
  description = "Toggle: write nexus/swarm/consul-gossip-key + placeholder nexus/swarm/consul-bootstrap-token to KV. Sticky one-time seed (preserves populated values). Default true."
  type        = bool
  default     = true
}

variable "enable_swarm_agent_setup" {
  description = "Master toggle for the 6 swarm-node Vault Agent setup primitives (policies + AppRoles). Default true. Set false on a foundation-only deploy that doesn't bring up the swarm tier."
  type        = bool
  default     = true
}

variable "enable_swarm_agent_policies" {
  description = "Toggle: write the 6 narrow Vault policies (nexus-agent-swarm-{manager,worker}-{1,2,3}). Default true (gated under enable_swarm_agent_setup)."
  type        = bool
  default     = true
}

variable "enable_swarm_agent_approles" {
  description = "Toggle: provision the 6 AppRoles + per-host JSON sidecars on the build host. Default true (gated under enable_swarm_agent_setup)."
  type        = bool
  default     = true
}

variable "vault_agent_swarm_creds_dir" {
  description = "Directory on the build host where the 6 vault-agent-swarm-<host>.json sidecars are written. Each contains role_id + secret_id + CA path + vault address for the corresponding swarm-node Vault Agent. Mode 0700 owner-only via icacls."
  type        = string
  default     = "$HOME/.nexus"
}
