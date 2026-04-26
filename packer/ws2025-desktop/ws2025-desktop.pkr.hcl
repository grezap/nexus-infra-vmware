/*
 * ws2025-desktop — NexusPlatform Windows Server 2025 *Desktop Experience*
 * base template (Phase 0.B.5)
 *
 * Sibling of ws2025-core. Same Autounattend, same shared PowerShell baseline
 * (packer/_shared/powershell/scripts/), same WinRM-build / OpenSSH-runtime
 * split. The only differences are the install.wim image name (Desktop
 * Experience SKU vs Core), bigger hardware defaults, and a Phase-0.B.5
 * delta provisioner that installs the desktop-admin tools (RSAT, GPMC, DNS
 * Server tools) needed for the future `dc-nexus` domain controller role.
 *
 * Why a separate template instead of a parameterised ws2025? Because the
 * install.wim image name is baked into Autounattend.xml at templatefile()
 * render time, and because Desktop Experience's RAM/disk profile is large
 * enough that you wouldn't want to pay for it on every Windows VM. Splitting
 * lets the SQL FCI/AG nodes (Core) stay lean while RSAT/DC nodes (Desktop)
 * carry their cost.
 *
 * Build:   make ws2025-desktop
 * Smoke:   make ws2025-desktop-smoke
 * See:     docs/ws2025-desktop.md
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

  # Desktop Experience edition names (vs Core in ws2025-core):
  #   evaluation → "Windows Server 2025 Standard Evaluation (Desktop Experience)"
  #   retail/MSDN → "Windows Server 2025 Standard (Desktop Experience)"
  image_name = (
    var.product_source == "msdn"
    ? "Windows Server 2025 Standard (Desktop Experience)"
    : "Windows Server 2025 Standard Evaluation (Desktop Experience)"
  )

  product_key = (
    var.product_source == "evaluation"
    ? ""
    : var.bootstrap_keys_file != ""
    ? jsondecode(file(var.bootstrap_keys_file))["ws2025-desktop"]["key"]
    : ""
  )

  # Same shared Autounattend template as ws2025-core; only image_name differs.
  autounattend_xml = templatefile("${path.root}/../_shared/powershell/floppy/Autounattend.xml.tpl", {
    image_name     = local.image_name
    product_key    = local.product_key
    admin_username = var.admin_username
    admin_password = var.admin_password
    computer_name  = var.vm_name
  })
}

# ─── Source: WS2025 (Desktop Experience), VMware Workstation builder ─────
source "vmware-iso" "ws2025_desktop" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = local.iso_path
  iso_checksum = local.iso_checksum

  guest_os_type = "windows2022srv-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0
  # WS2025 WinPE has no PVSCSI driver in-box -- same constraint as ws2025-core.
  disk_adapter_type = "lsisas1068"

  network_adapter_type = "e1000e"
  network              = "nat"

  version  = "20"
  firmware = "efi"

  floppy_content = {
    "Autounattend.xml" = local.autounattend_xml
  }
  floppy_files = [
    "../_shared/powershell/scripts/bootstrap-winrm.ps1"
  ]

  # Same EFI Boot Manager -> CDROM nav as ws2025-core; see comments there
  # for the full reasoning. WS2025 ISOs behave identically across editions.
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

  vmx_data = {
    "annotation"           = "ws2025-desktop Windows Server 2025 Desktop Experience base template (Phase 0.B.5) -- built by Packer"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + shared baseline + desktop delta + sysprep ───────
build {
  name    = "ws2025-desktop"
  sources = ["source.vmware-iso.ws2025_desktop"]

  # ── Stage authorized_keys (shared file) ──
  provisioner "file" {
    source      = "../_shared/powershell/files/nexusadmin-authorized_keys"
    destination = "C:/Windows/Temp/nexusadmin-authorized_keys"
  }

  # ── VMware Tools first ──
  provisioner "powershell" {
    scripts = [
      "../_shared/powershell/scripts/00-install-vmware-tools.ps1"
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # ── Shared Nexus baseline (same scripts as ws2025-core) ──
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
      "NEXUS_PHASE=0.B.5",
    ]
  }

  # ── Desktop-specific: RSAT, GPMC, DNS/DHCP server tools, Edge ──
  # Lives in this template (not _shared/) because it's the one thing that
  # legitimately differs between Core and Desktop. Adding it via a numbered
  # script keeps the failure-isolation semantics of the shared baseline.
  provisioner "powershell" {
    scripts = [
      "scripts/10-desktop-admin-tools.ps1"
    ]
  }
  # RSAT/GPMC/DNS-tools occasionally request a restart. Cheap to take it
  # before sysprep so /generalize sees a clean WMI/Component-Store state.
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # ── Sysprep (shared) ──
  provisioner "powershell" {
    scripts = [
      "../_shared/powershell/scripts/99-sysprep.ps1"
    ]
    valid_exit_codes = [0, 1, 2, 259, 2147942402]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
