/*
 * envs/foundation -- always-on lab plumbing.
 *
 * First Phase 0.C env. Composes two clones of the Phase-0.B.5
 * `ws2025-desktop` template via terraform/modules/vm/ to land the always-on
 * support fleet that every other env (data, ml, saas, microservices,
 * demo-minimal) depends on:
 *
 *   - dc-nexus              -- domain controller (AD DS promotion is the
 *                              role-overlay step, deferred; this stage just
 *                              lands the bare clone at a stable IP/MAC so
 *                              the overlay has a fixed target).
 *   - nexus-jumpbox   -- operator jump host. ws2025-desktop ships RSAT
 *                              MMC tools + GPMC, which is exactly what an
 *                              admin-tier jumpbox needs.
 *
 * Both VMs sit on VMnet11 (192.168.70.0/24) and DHCP from nexus-gateway in
 * the .200-.250 range. Static MACs are pinned for lease-discovery + future
 * dnsmasq host reservations.
 *
 * Shape mirrors terraform/ws2025-desktop-smoke/main.tf -- this is the
 * env-template the other 5 0.C envs will copy.
 */

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
    # Phase 0.D.4 -- vault_kv_secret_v2 data sources for nexus/foundation/*
    # bootstrap creds. Provider config + AppRole auth lives in vault-provider.tf.
    # Pinned to v4.x: v5 removed the `auth_login_approle` block (replaced by
    # the more general `auth_login` schema), and v4 is the LTS-friendly
    # release for the auth shape we use. Bumping to v5 is a 0.D.5+ refactor.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

module "dc_nexus" {
  source = "../../modules/vm"

  vm_name           = "dc-nexus"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/dc-nexus"
  vnet              = var.vnet
  mac_address       = var.mac_dc_nexus
}

module "nexus_admin_jumpbox" {
  source = "../../modules/vm"

  vm_name           = "nexus-jumpbox"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/nexus-jumpbox"
  vnet              = var.vnet
  mac_address       = var.mac_nexus_admin_jumpbox
}
