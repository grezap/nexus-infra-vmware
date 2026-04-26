/*
 * win11ent-smoke — verify the win11ent template + modules/vm/
 *
 * Same shape as ws2025-desktop-smoke (Phase 0.B.5): one clone of the
 * Phase-0.B.6 template attached to VMnet11 with a scratch MAC from the
 * smoke-test range (00:50:56:3F:00:24, one above ws2025-desktop-smoke's
 * :23 and ws2025-core-smoke's :22).
 *
 * Note on vTPM cloning: the template uses TPM-only encryption (only
 * .nvram is encrypted). `vmrun clone full` copies the .nvram with the
 * vTPM key blob, so the clone shares the template's TPM identity. That's
 * fine for smoke-test purposes (we're verifying clone+boot+OpenSSH+
 * windows_exporter, not vTPM uniqueness). Production clones with unique
 * vTPM identity per VM are a Phase 0.D concern.
 *
 * Exit gate: clone DHCPs from nexus-gateway, OpenSSH (:22) reachable,
 * windows_exporter (:9182) returns metrics, `dotnet --version` returns
 * 10.x.y, and `wt.exe` is on PATH.
 *
 * Usage:
 *   make win11ent-smoke
 *   make win11ent-smoke-destroy
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

module "win11ent_smoke" {
  source = "../modules/vm"

  vm_name           = "win11ent-smoke"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = var.vm_output_dir
  vnet              = "VMnet11"
  mac_address       = var.mac_address
}
