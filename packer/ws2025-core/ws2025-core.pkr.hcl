/*
 * ws2025-core — NexusPlatform Windows Server 2025 Core base template (Phase 0.B.4)
 *
 * Headless Windows server image. Parent for future VMs that need Windows
 * userspace (SQL Server FCI + AG nodes, Windows-specific service hosts)
 * but no desktop — SQL Server and most service workloads don't need one.
 *
 * Key departures from the Debian/Ubuntu templates:
 *
 *   - Communicator: WinRM over HTTP (build-time only; listener torn down
 *     at sysprep). OpenSSH Server is installed as the *runtime* remote
 *     access path; the build-time WinRM channel is Packer-only.
 *
 *   - No Ansible. The Phase 0.B.3 `_shared/ansible/roles/nexus_*` roles
 *     are Linux-specific (systemd, nftables, systemd-networkd, chrony).
 *     Windows gets a parallel set of PowerShell provisioner scripts
 *     under scripts/ that do the same jobs via Windows-native mechanisms
 *     (Windows Firewall, W32Time, netsh, Set-NetAdapterAdvancedProperty,
 *     windows_exporter). Shared Windows logic will DRY-extract when the
 *     second Windows template (ws2025-desktop, Phase 0.B.5) lands — same
 *     two-call-sites principle as the Linux shared roles.
 *
 *   - Unattend delivered via floppy (A:\Autounattend.xml), not an HTTP
 *     server. Windows Setup auto-discovers Autounattend.xml on attached
 *     removable media before falling back to the network.
 *
 *   - product_source variable selects evaluation ISO (180-day, no key)
 *     vs retail/MSDN ISO (genuine activation from Vault or bootstrap
 *     JSON). See docs/licensing.md.
 *
 * Build:   make ws2025-core
 * Smoke:   make ws2025-core-smoke
 * See:     docs/ws2025-core.md
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

  # install.wim image Name strings (from `dism /Get-ImageInfo` on each ISO):
  #   evaluation ISO → "Windows Server 2025 Standard Evaluation"
  #   retail/MSDN    → "Windows Server 2025 Standard"
  image_name = (
    var.product_source == "msdn"
    ? "Windows Server 2025 Standard"
    : "Windows Server 2025 Standard Evaluation"
  )

  # product_key precedence:
  #   evaluation              → "" (empty; Setup accepts no key and picks eval edition)
  #   msdn + bootstrap_keys_file set → read from JSON (NTFS-ACL locked owner file)
  #   msdn + Vault (post-0.D)        → vault function (not used yet; stub kept for parity with docs/licensing.md)
  #
  # The vault() path is intentionally *not* wired up pre-Phase-0.D — attempting
  # to use it without VAULT_ADDR/VAULT_TOKEN and a live Vault will fail fast
  # with a clear error. Use bootstrap_keys_file until Vault exists.
  product_key = (
    var.product_source == "evaluation"
    ? ""
    : var.bootstrap_keys_file != ""
    ? jsondecode(file(var.bootstrap_keys_file))["ws2025-core"]["key"]
    : ""
  )

  # Renders Autounattend.xml with the build-time-dynamic fields inlined.
  # The rendered form lands on the floppy image in the VM as A:\Autounattend.xml.
  # It is *not* written to disk — floppy_content provides the rendered bytes
  # directly to Packer's floppy builder. Therefore no gitignored artifact is
  # produced on the build host, which closes the main leak vector for the key.
  autounattend_xml = templatefile("${path.root}/floppy/Autounattend.xml.tpl", {
    image_name     = local.image_name
    product_key    = local.product_key
    admin_username = var.admin_username
    admin_password = var.admin_password
    computer_name  = var.vm_name
  })
}

# ─── Source: WS2025 (Core), VMware Workstation builder ────────────────────
source "vmware-iso" "ws2025_core" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  # ISO
  iso_url      = local.iso_path
  iso_checksum = local.iso_checksum

  # Hardware — WS2025 guest_os_type is not in Workstation 17's catalog yet;
  # windows2022srv-64 is the correct fallback (same NT 10 kernel family).
  guest_os_type = "windows2022srv-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK
  # WS2025 WinPE doesn't include the VMware PVSCSI driver -- Setup can't see
  # the disk and shows an empty "Select location to install Windows" list.
  # lsilogic-sas is built into Windows Setup's driver store; post-install,
  # 00-install-vmware-tools.ps1 adds the PVSCSI driver for runtime VMs.
  disk_adapter_type = "lsisas1068"

  # Single NIC, NAT during build for Windows Update / VMware Tools fetch.
  # Terraform modules/vm/ attaches the real VMnet11 NIC at clone time.
  network_adapter_type = "e1000e" # WS2025 ships e1000e drivers out-of-box; vmxnet3 requires Tools
  network              = "nat"

  # WS 17+ hardware version. Firmware UEFI — WS2025 Setup refuses legacy BIOS
  # on modern builds and an EFI System Partition is standard.
  version  = "20"
  firmware = "efi"

  # Floppy with the rendered Autounattend + the bootstrap scripts that
  # FirstLogonCommands reaches for.
  floppy_content = {
    "Autounattend.xml" = local.autounattend_xml
  }
  floppy_files = [
    "scripts/bootstrap-winrm.ps1"
  ]

  # Windows Server 2025 ISOs show "Press any key to boot from CD or DVD..." for
  # ~5 seconds. If no key is pressed, EFI falls through past the empty disk and
  # lands at the UEFI Boot Manager menu (stuck). We send a burst of <enter>s to
  # catch that window. Once Setup is running it reads Autounattend.xml from A:\
  # and the install is hands-off from there.
  # EFI firmware on WS2025 ISOs does NOT honor keystrokes during its
  # device-probe phase, and there's no reliable press-any-key window on the
  # CDROM. Instead, let EFI walk through its default boot order (empty HDD ->
  # CDROM probe -> Floppy -> Network timeout) and land at the Boot Manager
  # menu. Then we navigate explicitly to "EFI VMware Virtual IDE CDROM Drive".
  #
  # Boot Manager layout (cursor starts on "Boot normally"):
  #   > Boot normally
  #     EFI VMware Virtual SCSI Hard Drive (0.0)
  #     EFI VMware Virtual IDE CDROM Drive (IDE 0:0)   <-- down x2 + enter
  #     EFI Floppy
  #     EFI Network
  #     ...
  # 90s is conservative -- Network probe alone can take ~30s to time out.
  boot_wait    = "90s"
  boot_command = [
    # Stage 1: navigate EFI Boot Manager -> "EFI VMware Virtual IDE CDROM".
    "<down><down><enter>",
    # Stage 2: "Press any key to boot from CD or DVD..." -- ~5s window.
    # One spacebar is enough; more can pollute Setup's keyboard buffer and
    # cause the initial Setup UI to crash (observed: blue-screen-then-reboot
    # loop with 16 spacebars).
    "<wait3><spacebar>",
    # Stage 3: Windows Boot Manager from CD -- "Windows Setup [EMS Enabled]"
    # is default-highlighted; press Enter to proceed into Setup.
    "<wait5><enter>",
  ]

  # WinRM — listener enabled via FirstLogonCommands → bootstrap-winrm.ps1.
  communicator   = "winrm"
  winrm_username = var.admin_username
  winrm_password = var.admin_password
  winrm_insecure = true # build-time plaintext HTTP; torn down in 99-sysprep.ps1
  winrm_use_ssl  = false
  winrm_timeout  = var.winrm_timeout
  winrm_port     = 5985

  # Graceful shutdown via sysprep (the 99-sysprep.ps1 script runs
  # generalize + shutdown, so Packer's shutdown_command is a no-op wait).
  shutdown_command = "powershell -NoProfile -Command \"Write-Host 'sysprep handled shutdown; waiting'\""
  shutdown_timeout = "30m"

  headless = true

  # VMware Tools — upload windows.iso from the Workstation install to
  # C:\Windows\Temp\windows.iso; scripts/05-windows-baseline.ps1 mounts
  # and installs it silently.
  tools_mode          = "upload"
  tools_upload_flavor = "windows"
  tools_upload_path   = "C:\\Windows\\Temp\\windows.iso"

  # Strip NIC config — Terraform modules/vm/ rewrites it post-clone, same
  # pattern as deb13/ubuntu24.
  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "ws2025-core Windows Server 2025 Core base template (Phase 0.B.4) -- built by Packer"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS via Autounattend + post-install PowerShell ────────
build {
  name    = "ws2025-core"
  sources = ["source.vmware-iso.ws2025_core"]

  # ── Stage the authorized_keys file for nexusadmin's OpenSSH config ────
  provisioner "file" {
    source      = "files/nexusadmin-authorized_keys"
    destination = "C:/Windows/Temp/nexusadmin-authorized_keys"
  }

  # ── VMware Tools (mount C:\Windows\Temp\windows.iso + silent install) ──
  # Runs first so subsequent reboots have Tools-aware shutdown/time sync.
  provisioner "powershell" {
    scripts = [
      "scripts/00-install-vmware-tools.ps1"
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # ── Nexus baseline (PowerShell parallel to the Linux shared roles) ────
  # Each script is the Windows analog of one of the _shared/ansible/roles.
  # Kept as separate numbered scripts so a failure stops at the offending
  # layer and logs are obvious; final DRY extraction will split these into
  # _shared/powershell/modules/ when ws2025-desktop lands (Phase 0.B.5).
  provisioner "powershell" {
    scripts = [
      "scripts/01-nexus-identity.ps1",      # nexusadmin user, OpenSSH Server, authorized_keys, sshd hardening
      "scripts/02-nexus-network.ps1",       # NIC rename nic0, static DNS at 192.168.70.1, W32Time client
      "scripts/03-nexus-firewall.ps1",      # Windows Firewall baseline (deny-in + SSH/5986/9182 from VMnet11)
      "scripts/04-nexus-observability.ps1", # windows_exporter service on :9182
      "scripts/05-windows-baseline.ps1",    # Defender AV baseline, telemetry off, login banner, Start Menu pins sanity
    ]
    environment_vars = [
      "NEXUS_ADMIN_USERNAME=${var.admin_username}"
    ]
  }

  # ── Sysprep: tear down WinRM build listener, generalize, shutdown ────
  # Packer's shutdown_command is a no-op; sysprep handles the actual poweroff.
  provisioner "powershell" {
    scripts = [
      "scripts/99-sysprep.ps1"
    ]
    # Expect non-zero while the VM powers off; don't fail the build on that.
    valid_exit_codes = [0, 1, 2, 259, 2147942402]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
