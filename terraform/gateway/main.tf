/*
 * nexus-gateway — Terraform root module
 *
 * Instantiates the Packer-built nexus-gateway template as the VM #0 of the
 * NexusPlatform fleet. Three NICs mapped to: bridged, VMnet11, VMnet10.
 *
 * Lifecycle driver: `vmrun` CLI (ships with VMware Workstation).
 *
 * Historical note: Phase 0.B.1 originally tried the elsudano/vmworkstation
 * Terraform provider (v2.0.1). It has two blocker bugs against vmrest 17.6.x:
 *   1. `vmworkstation_virtual_machine` ignores the `path` attribute — it
 *      always clones into `%USERPROFILE%\Documents\Virtual Machines\<name>`,
 *      then returns that path, which fails Terraform's post-apply consistency
 *      check when you asked for a different destination.
 *   2. The SDK's clone-then-reconstruct-NIC sequence sends `vmnet8` alongside
 *      `connectionType=nat`, which vmrest rejects as "Redundant parameter"
 *      (upstream issue elsudano/terraform-provider-vmworkstation#28).
 * Rather than pin an older/buggier v1.x provider, we drive vmrun directly via
 * `null_resource` — gives us full control of the destination path and avoids
 * the vmrest PUT bugs entirely. vmrest is still running so future `nexus-cli`
 * introspection can query VM state by path.
 *
 * Usage:
 *   terraform init
 *   terraform apply
 */

terraform {
  required_version = ">= 1.9.0"
  required_providers {
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

locals {
  vmrun        = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
  template_vmx = var.template_vmx_path
  target_vmx   = "${var.vm_output_dir}/nexus-gateway.vmx"
  scripts_dir  = abspath("${path.module}/../../scripts")
}

# ─── Clone the Packer-built template → running VM instance ────────────────
resource "null_resource" "clone_vm" {
  triggers = {
    template_vmx = local.template_vmx
    target_vmx   = local.target_vmx
    vmrun        = local.vmrun # mirrored into triggers so destroy-time provisioners can see it
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $src = '${local.template_vmx}'
      $dst = '${local.target_vmx}'
      if (-not (Test-Path $src)) { throw "Template VMX not found: $src" }
      if (Test-Path $dst)        { throw "Destination already exists: $dst — rm it or taint this resource." }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
      & '${local.vmrun}' clone $src $dst full -cloneName=nexus-gateway
      if ($LASTEXITCODE -ne 0) { throw "vmrun clone failed with exit code $LASTEXITCODE" }
      if (-not (Test-Path $dst)) { throw "vmrun reported success but $dst was not created." }
      Write-Host "Cloned template → $dst"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $dst   = '${self.triggers.target_vmx}'
      $vmrun = '${self.triggers.vmrun}'
      if (Test-Path $dst) {
        # Stop first if running, then delete the .vmx + parent dir
        & $vmrun stop $dst hard 2>$null
        & $vmrun deleteVM $dst 2>$null
        Remove-Item -Recurse -Force (Split-Path -Parent $dst) -ErrorAction SilentlyContinue
      }
    PWSH
  }
}

# ─── NIC configuration ────────────────────────────────────────────────────
# The template ships with one host-only NIC (build-time artifact). This step
# strips it and writes the three real NICs with pinned MACs on
# bridged / VMnet11 / VMnet10.
resource "null_resource" "configure_nics" {
  triggers = {
    target_vmx = local.target_vmx
    mac_nic0   = var.mac_nic0
    mac_nic1   = var.mac_nic1
    mac_nic2   = var.mac_nic2
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      & '${local.scripts_dir}/configure-gateway-nics.ps1' `
          -VmxPath '${local.target_vmx}' `
          -MacNic0 '${var.mac_nic0}' `
          -MacNic1 '${var.mac_nic1}' `
          -MacNic2 '${var.mac_nic2}'
    PWSH
  }

  depends_on = [null_resource.clone_vm]
}

# ─── Power on ─────────────────────────────────────────────────────────────
resource "null_resource" "power_on" {
  triggers = {
    target_vmx = local.target_vmx
    vmrun      = local.vmrun
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "& '${local.vmrun}' start '${local.target_vmx}' nogui"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "& '${self.triggers.vmrun}' stop '${self.triggers.target_vmx}' hard 2>$null; exit 0"
  }

  depends_on = [null_resource.configure_nics]
}
