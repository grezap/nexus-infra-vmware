/*
 * envs/security -- Phase 0.D.1: 3-node Vault Raft cluster.
 *
 * Per nexus-platform-plan/docs/infra/vms.yaml lines 55-57 + MASTER-PLAN.md
 * Phase 0.D goal (line 145):
 *
 *   - 3 Debian-13 VMs (vault-1, vault-2, vault-3)
 *   - Foundation tier directory: H:/VMS/NexusPlatform/01-foundation/vault-N
 *   - Dual-NIC: VMnet11 service network (DHCP via dnsmasq dhcp-host
 *     reservation -> .121/.122/.123) + VMnet10 cluster backplane (static
 *     IP per hostname mapping in vault-firstboot.sh)
 *   - 2 vCPU, 2 GB RAM each (RAM = approved deviation; vms.yaml says 4 GB)
 *   - 40 GB disk each
 *
 * Why a separate env (not extending envs/foundation/):
 *   User decision 2026-04-29 -- envs/security/ keeps Vault iteration
 *   isolated from foundation env's AD plumbing. Same 01-foundation/ tier
 *   directory per vms.yaml.
 *
 * MAC convention (per docs/handbook.md s 1a + memory feedback):
 *   00:50:56:3F:00:40-42  -> primary NICs (VMnet11)   for vault-1/2/3
 *   00:50:56:3F:01:40-42  -> secondary NICs (VMnet10) for vault-1/2/3
 *
 * Selective ops (per memory/feedback_selective_provisioning.md):
 *   - var.enable_vault_cluster (default true) gates the entire env
 *   - Per-node `-target=module.vault_N` for iteration
 *   - role-overlay-vault-cluster.tf wires init + unseal + raft join +
 *     KV-v2 + auth methods AFTER all 3 clones are up; toggleable via
 *     var.enable_vault_init
 */

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# Pre-check: the dnsmasq dhcp-host reservations on nexus-gateway must be in
# place BEFORE these clones boot, otherwise they'll DHCP into the dynamic
# pool (.200-.250) instead of getting their canonical .121/.122/.123. The
# reservations are managed by the foundation env's gateway overlay
# (role-overlay-gateway-vault-reservations.tf, gated on
# var.enable_vault_dhcp_reservations). Operator order:
#
#   1. Foundation env: terraform apply -var enable_vault_dhcp_reservations=true
#      (or scripts\foundation.ps1 apply -Vars enable_vault_dhcp_reservations=true)
#   2. Vault Packer template built: packer build packer/vault/
#   3. THIS env: terraform apply  (or scripts\security.ps1 apply)
#
# We don't enforce this in HCL because envs are independent terraform states
# (per local-state-until-Phase-0.E). The wrapper scripts and handbook s 2
# document the order.

module "vault_1" {
  source = "../../modules/vm"
  count  = var.enable_vault_cluster ? 1 : 0

  vm_name           = "vault-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/vault-1"

  # Primary: VMnet11 service network (.121 via dhcp-host reservation)
  vnet        = var.vnet_primary
  mac_address = var.mac_vault_1_primary

  # Secondary: VMnet10 cluster backplane (.121 via vault-firstboot.sh static config)
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_vault_1_secondary
}

module "vault_2" {
  source = "../../modules/vm"
  count  = var.enable_vault_cluster ? 1 : 0

  vm_name           = "vault-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/vault-2"

  vnet        = var.vnet_primary
  mac_address = var.mac_vault_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_vault_2_secondary
}

module "vault_3" {
  source = "../../modules/vm"
  count  = var.enable_vault_cluster ? 1 : 0

  vm_name           = "vault-3"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/vault-3"

  vnet        = var.vnet_primary
  mac_address = var.mac_vault_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_vault_3_secondary
}

# Phase 0.D.5.5 -- vault-transit single-node companion. Hosts the transit
# engine + seal key consumed by vault-1/2/3 for auto-unseal. Per
# memory/feedback_vmware_per_vm_folders.md: own subdir under foundation tier.
module "vault_transit" {
  source = "../../modules/vm"
  count  = var.enable_vault_transit_unseal && var.enable_vault_transit_vm ? 1 : 0

  vm_name           = "vault-transit"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/vault-transit"

  vnet        = var.vnet_primary
  mac_address = var.mac_vault_transit_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_vault_transit_secondary
}
