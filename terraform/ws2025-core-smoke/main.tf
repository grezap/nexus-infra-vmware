/*
 * ws2025-core-smoke — verify the ws2025-core template + terraform/modules/vm/
 *
 * Instantiates exactly one clone of the ws2025-core template via modules/vm/,
 * attached to VMnet11 with a scratch MAC (:22 from the smoke-test range —
 * one above ubuntu24-smoke's :21).
 *
 * After `terraform apply`, the VM should:
 *   - DHCP from nexus-gateway's dnsmasq (IP in 192.168.70.200-.250)
 *   - Be reachable over SSH (OpenSSH Server, key-only) on :22
 *   - Expose windows_exporter on :9182 (reachable from VMnet11 only per fw)
 *   - Accept ICMPv4 Echo from VMnet11 (so Test-Connection loops work)
 *
 * This env is disposable — `terraform destroy` wipes everything.
 *
 * Usage:
 *   make ws2025-core-smoke          # terraform apply
 *   make ws2025-core-smoke-destroy  # tear down
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

module "ws2025_core_smoke" {
  source = "../modules/vm"

  vm_name           = "ws2025-core-smoke"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = var.vm_output_dir
  vnet              = "VMnet11"
  mac_address       = var.mac_address
}
