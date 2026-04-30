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
