/*
 * nexus-gateway — Terraform root module
 *
 * Instantiates the Packer-built nexus-gateway template as the VM #0 of the
 * NexusPlatform fleet. Three NICs mapped to: bridged, VMnet11, VMnet10.
 *
 * Provider: elsudano/vmware-desktop (VMware Workstation/Fusion REST API).
 * Fallback: if the REST daemon isn't running on the host, use vmrun via
 * null_resource. See README.md § "vmrun fallback".
 *
 * Usage:
 *   terraform init
 *   terraform apply
 */

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = ">= 1.2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
  }
}

provider "vmworkstation" {
  user       = var.vmware_workstation_user
  password   = var.vmware_workstation_password
  url        = var.vmware_workstation_api_url
  https      = false
  debug      = false
}

# ─── The VM itself ────────────────────────────────────────────────────────
resource "vmworkstation_vm" "nexus_gateway" {
  sourceid     = var.template_id
  denomination = "nexus-gateway"
  description  = "NexusPlatform lab edge router — VM #0. nftables NAT · dnsmasq DHCP+DNS · chrony NTP."
  path         = var.vm_output_dir

  processors = 1
  memory     = 512
}

# ─── NIC configuration — vmrun/vmx-edit fallback ──────────────────────────
# The vmworkstation provider does not expose per-NIC network type/MAC as of
# v1.2.0, so we drive NIC mapping + MAC pinning via vmrun + vmx edits.
# This is idempotent: the null_resource triggers on template_id OR vm id change.

resource "null_resource" "configure_nics" {
  triggers = {
    vm_id       = vmworkstation_vm.nexus_gateway.id
    template_id = var.template_id
    mac_nic0    = var.mac_nic0
    mac_nic1    = var.mac_nic1
    mac_nic2    = var.mac_nic2
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $vmx = Join-Path '${var.vm_output_dir}' 'nexus-gateway.vmx'
      if (-not (Test-Path $vmx)) { throw "VMX not found at $vmx — Terraform apply did not produce it." }
      & '${abspath(path.module)}/../../scripts/configure-gateway-nics.ps1' `
          -VmxPath $vmx `
          -MacNic0 '${var.mac_nic0}' `
          -MacNic1 '${var.mac_nic1}' `
          -MacNic2 '${var.mac_nic2}'
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "Write-Host 'Skipping NIC unconfig on destroy — VMX is deleted by vmworkstation_vm.'"
  }

  depends_on = [vmworkstation_vm.nexus_gateway]
}

# ─── Power on after NICs are configured ───────────────────────────────────
resource "null_resource" "power_on" {
  triggers = {
    vm_id = vmworkstation_vm.nexus_gateway.id
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $vmx = Join-Path '${var.vm_output_dir}' 'nexus-gateway.vmx'
      & 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' start $vmx nogui
    PWSH
  }

  depends_on = [null_resource.configure_nics]
}
