/*
 * ws2025-desktop-smoke — verify the ws2025-desktop template + modules/vm/
 *
 * Same shape as ws2025-core-smoke (Phase 0.B.4): one clone of the
 * Phase-0.B.5 template attached to VMnet11 with a scratch MAC from the
 * smoke-test range (00:50:56:3F:00:23, one above ws2025-core-smoke's :22).
 *
 * Exit gate: clone DHCPs from nexus-gateway, OpenSSH (:22) reachable,
 * windows_exporter (:9182) returns metrics, RSAT MMC snap-ins discoverable
 * (`Get-WindowsFeature RSAT-AD-Tools` returns Installed). Domain promotion
 * is deferred to the dc-nexus role overlay -- this template stays generic.
 *
 * Usage:
 *   make ws2025-desktop-smoke
 *   make ws2025-desktop-smoke-destroy
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

module "ws2025_desktop_smoke" {
  source = "../modules/vm"

  vm_name           = "ws2025-desktop-smoke"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = var.vm_output_dir
  vnet              = "VMnet11"
  mac_address       = var.mac_address
}
