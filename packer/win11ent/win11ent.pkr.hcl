/*
 * win11ent — NexusPlatform Windows 11 Enterprise client workstation
 * base template (Phase 0.B.6)
 *
 * Final Windows template before Phase 0.C terraform fleet provisioning.
 * Used for nexus-desk integration testing and the WinForms/WPF/WinUI 3
 * portfolio demos (the desktop-app side of the Nexus showcase).
 *
 * Reuses the entire packer/_shared/powershell/ bundle:
 *   - floppy/Autounattend.xml.tpl   (image_name + bypass_win11_checks)
 *   - scripts/00-install-vmware-tools.ps1
 *   - scripts/01-nexus-identity.ps1     ← identity, OpenSSH, nexusadmin, key
 *   - scripts/02-nexus-network.ps1      ← network/DNS baseline
 *   - scripts/03-nexus-firewall.ps1     ← firewall: SSH + windows_exporter
 *   - scripts/04-nexus-observability.ps1 ← windows_exporter on :9182
 *   - scripts/05-windows-baseline.ps1   ← Update policy, telemetry, TLS
 *   - scripts/99-sysprep.ps1
 * The win11ent delta is a single client-tooling script under scripts/.
 *
 * Win11 install gate: Setup checks TPM 2.0 + Secure Boot + RAM. Standalone
 * VMware Workstation cannot expose a real vTPM to Packer headlessly, so
 * the gate is satisfied via LabConfig regkeys written by Autounattend's
 * windowsPE RunSynchronousCommands (bypass_win11_checks=true). See README.
 *
 * Build:   make win11ent
 * Smoke:   make win11ent-smoke
 * See:     packer/win11ent/README.md, docs/licensing.md
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

# ─── Derived locals: ISO + image + product key per product_source ─────────
locals {
  iso_path = (
    var.product_source == "msdn"
    ? var.iso_path_msdn
    : var.iso_path_evaluation
  )

  iso_checksum = (
    var.product_source == "msdn"
    ? var.iso_checksum_msdn
    : var.iso_checksum_evaluation
  )

  # Win11 install.wim image names (verify with `dism /Get-ImageInfo` if Setup
  # can't find the image — Microsoft has changed these strings between 22H2
  # and 23H2 builds in the past).
  #   evaluation → "Windows 11 Enterprise Evaluation"
  #   retail/MSDN → "Windows 11 Enterprise"
  image_name = (
    var.product_source == "msdn"
    ? "Windows 11 Enterprise"
    : "Windows 11 Enterprise Evaluation"
  )

  product_key = (
    var.product_source == "evaluation"
    ? ""
    : var.bootstrap_keys_file != ""
    ? jsondecode(file(var.bootstrap_keys_file))["win11ent"]["key"]
    : ""
  )

  # Same shared Autounattend template as the WS2025 templates. Win11
  # Enterprise honors LocalAccount + AutoLogon and the OOBE skip flags
  # without needing the BypassNRO registry hack that Win11 Pro/Home would.
  # bypass_win11_checks=true emits the LabConfig RunSynchronousCommands
  # that skip the TPM/Secure-Boot/RAM gates -- see template header for
  # the full rationale (standalone Workstation can't expose a real vTPM
  # to Packer headlessly).
  autounattend_xml = templatefile("${path.root}/../_shared/powershell/floppy/Autounattend.xml.tpl", {
    image_name          = local.image_name
    product_key         = local.product_key
    admin_username      = var.admin_username
    admin_password      = var.admin_password
    computer_name       = var.vm_name
    bypass_win11_checks = true
  })
}

# ─── Source: Win11 Enterprise, VMware Workstation builder ─────────────────
source "vmware-iso" "win11ent" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = local.iso_path
  iso_checksum = local.iso_checksum

  guest_os_type = "windows11-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  # Win11 WinPE ships the pvscsi driver in-box (unlike WS2025 WinPE, which
  # forced lsisas1068 in ws2025-core). If a future build hits "no driver for
  # boot disk" during install, swap to:
  #   disk_adapter_type = "lsisas1068"
  disk_adapter_type = "pvscsi"

  network_adapter_type = "e1000e"
  network              = "nat"

  # HW version 20 matches the WS2025 templates; UEFI required by Win11.
  version  = "20"
  firmware = "efi"

  floppy_content = {
    "Autounattend.xml" = local.autounattend_xml
  }
  floppy_files = [
    "../_shared/powershell/scripts/bootstrap-winrm.ps1"
  ]

  # Same EFI Boot Manager → CDROM nav as the WS2025 templates: the menu
  # layout and "press any key to boot from CD" prompt are identical across
  # modern Microsoft installer ISOs. Adjust waits if the Win11 ISO needs
  # more time on this build host.
  boot_wait = "90s"
  boot_command = [
    "<down><down><enter>",
    "<wait3><spacebar>",
    "<wait5><enter>",
  ]

  communicator   = "winrm"
  winrm_username = var.admin_username
  winrm_password = var.admin_password
  winrm_insecure = true
  winrm_use_ssl  = false
  winrm_timeout  = var.winrm_timeout
  winrm_port     = 5985

  shutdown_command = "powershell -NoProfile -Command \"Write-Host 'sysprep handled shutdown; waiting'\""
  shutdown_timeout = "30m"

  headless = true

  tools_mode        = "attach"
  tools_source_path = "C:/Program Files (x86)/VMware/VMware Workstation/windows.iso"

  vmx_remove_ethernet_interfaces = true

  # No vTPM keys: standalone Workstation ignores managedvm.autoAddVTPM
  # (vSphere-only) and the install-time gate is satisfied via LabConfig
  # bypass instead. See template header for context.
  vmx_data = {
    "annotation"           = "win11ent Windows 11 Enterprise base template (Phase 0.B.6) -- built by Packer"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + shared baseline + win11ent delta + sysprep ──────
build {
  name    = "win11ent"
  sources = ["source.vmware-iso.win11ent"]

  # ── Stage authorized_keys (shared file) ──
  provisioner "file" {
    source      = "../_shared/powershell/files/nexusadmin-authorized_keys"
    destination = "C:/Windows/Temp/nexusadmin-authorized_keys"
  }

  # ── elevated_user/password: Win11 specific ─────────────────────────────
  # Win11 (unlike Server SKUs) gives Packer's WinRM-launched PowerShell a
  # session that lacks the privileges DISM/TrustedInstaller need for
  # Add-WindowsCapability, Install-WindowsFeature, and similar setup-level
  # operations. LocalAccountTokenFilterPolicy=1 in bootstrap-winrm.ps1
  # helps for most cmdlets but not for DISM. Packer's elevated_user
  # parameters wrap each provisioner in a scheduled task that runs with
  # HighestAvailable run-level, which bypasses UAC entirely. We apply it
  # to every PowerShell provisioner below for consistency.

  # ── VMware Tools first ──
  provisioner "powershell" {
    scripts           = ["../_shared/powershell/scripts/00-install-vmware-tools.ps1"]
    elevated_user     = var.admin_username
    elevated_password = var.admin_password
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # ── Shared Nexus baseline (same scripts as the WS2025 templates) ──
  # All five scripts are OS-agnostic across WS2025/Win11: they touch only
  # registry policy keys, scheduled tasks, SCHANNEL, and pagefile WMI —
  # nothing Server-only. The Server-Manager-disable in 05 no-ops on Win11
  # because the task path doesn't exist (Get-ScheduledTask returns $null,
  # the if-guard skips Disable-ScheduledTask).
  provisioner "powershell" {
    scripts = [
      "../_shared/powershell/scripts/01-nexus-identity.ps1",
      "../_shared/powershell/scripts/02-nexus-network.ps1",
      "../_shared/powershell/scripts/03-nexus-firewall.ps1",
      "../_shared/powershell/scripts/04-nexus-observability.ps1",
      "../_shared/powershell/scripts/05-windows-baseline.ps1",
    ]
    environment_vars = [
      "NEXUS_ADMIN_USERNAME=${var.admin_username}",
      "NEXUS_TEMPLATE_NAME=${var.vm_name}",
      "NEXUS_PHASE=0.B.6",
    ]
    elevated_user     = var.admin_username
    elevated_password = var.admin_password
  }

  # ── Win11 client tooling delta (.NET 10 SDK, WinAppSDK, Terminal) ──
  # Lives in this template (not _shared/) because it's the developer-
  # workstation profile that justifies a separate Win11 template over the
  # WS2025-Desktop admin profile. winget-driven; idempotent.
  provisioner "powershell" {
    scripts           = ["scripts/10-win11ent-client-tools.ps1"]
    elevated_user     = var.admin_username
    elevated_password = var.admin_password
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # ── Sysprep (shared) ──
  provisioner "powershell" {
    scripts           = ["../_shared/powershell/scripts/99-sysprep.ps1"]
    valid_exit_codes  = [0, 1, 2, 259, 2147942402]
    elevated_user     = var.admin_username
    elevated_password = var.admin_password
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
