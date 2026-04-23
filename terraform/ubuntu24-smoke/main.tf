/*
 * ubuntu24-smoke — verify the ubuntu24 base template + terraform/modules/vm/
 *
 * Instantiates exactly one clone of the ubuntu24 template via modules/vm/,
 * attached to VMnet11 with a scratch MAC (:21 from the smoke-test range,
 * one step above deb13-smoke's :20).
 *
 * After `terraform apply`, the VM should:
 *   - DHCP from nexus-gateway's dnsmasq (IP in 192.168.70.200-.250)
 *   - Be reachable over SSH from the Windows host on that DHCP IP
 *   - Expose node_exporter on :9100 (reachable from VMnet11 only per nft)
 *
 * This env is disposable — `terraform destroy` wipes everything.
 *
 * Usage:
 *   make ubuntu24-smoke          # terraform apply
 *   make ubuntu24-smoke-destroy  # tear down
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

module "ubuntu24_smoke" {
  source = "../modules/vm"

  vm_name           = "ubuntu24-smoke"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = var.vm_output_dir
  vnet              = "VMnet11"
  mac_address       = var.mac_address
}
