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
