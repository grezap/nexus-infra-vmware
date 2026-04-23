/*
 * ubuntu24 — NexusPlatform generic Ubuntu 24.04 LTS base template (Phase 0.B.3)
 *
 * Second generic base image alongside deb13. Future role-specific VMs clone
 * this template via terraform/modules/vm/ and overlay their own Ansible.
 *
 * Shape matches deb13 exactly, with three Ubuntu-specific differences:
 *   - Installer: Canonical Subiquity autoinstall (cloud-init NoCloud) instead
 *     of Debian d-i preseed.
 *   - Boot path: /casper/vmlinuz + /casper/initrd (live-server image) instead
 *     of the d-i kernel path.
 *   - Unattended-upgrades origin pattern: Ubuntu:${distro_codename}-security
 *     (done in the ubuntu_base Ansible role, not here).
 *
 * Everything else (NIC rename en*→nic0, nftables baseline, chrony client
 * pointed at 192.168.70.1, node_exporter on :9100, hardened sshd, SSH
 * host-key regen drop-in, owner pubkey bake-in) is behaviourally identical
 * to deb13. The Phase 0.B.3 DRY refactor extracts those into shared roles.
 *
 * Build:   make ubuntu24
 * Smoke:   make ubuntu24-smoke
 * See:     docs/ubuntu24.md
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ─── Source: Ubuntu 24.04 live-server ISO, VMware Workstation builder ─────
source "vmware-iso" "ubuntu24" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  # ISO
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # Hardware
  guest_os_type = "ubuntu-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

  # Single NIC — Terraform attaches the real VMnet11 NIC at clone time via
  # modules/vm/. Build-time NAT is just for apt fetch.
  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20" # WS 17+ hw version

  # Autoinstall delivered via Packer's HTTP server (user-data + meta-data)
  http_directory = "http"
  boot_wait      = var.boot_wait

  # Drop into GRUB shell, hand-load the live-server kernel with autoinstall
  # kernel args pointing at Packer's HTTP server (NoCloud data source).
  # Notes on the exact form (hard-won):
  #   - `c` enters GRUB's command shell. Must wait for it to appear before
  #     typing; the menu takes ~3s to render on first power-on.
  #   - Single-quote the ds= value so GRUB's shell keeps the literal `;`.
  #     Double-quotes get eaten and the semicolon acts as a command separator,
  #     which drops a silent GRUB shell — no kernel ever loads and the VNC
  #     keystrokes go into the void. That's the 48-minute-SSH-timeout failure
  #     mode we hit on the first build attempt.
  #   - `---` at the end separates kernel args from init args (idiomatic);
  #     keep it to match the live-server stock GRUB entry shape.
  boot_command = [
    "<wait5>c<wait5>",
    "linux /casper/vmlinuz autoinstall 'ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/' ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  # SSH
  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  # Graceful shutdown
  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  # Strip all ethernet*.* lines — Terraform modules/vm/ rewrites the single
  # NIC entry post-clone. Same pattern as deb13.
  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "ubuntu24 generic base template (Phase 0.B.3) — built by Packer"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + hand off to Ansible for role config ──────────────
build {
  name    = "ubuntu24"
  sources = ["source.vmware-iso.ubuntu24"]

  # Stage static config files the role expects
  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  # Settle + install Ansible on-box (ansible-local runs ansible-playbook here).
  # cloud-init may still be finalizing at first login — wait for it.
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "sudo cloud-init status --wait || true",
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-apt sudo ansible"
    ]
  }

  # Apply the shared nexus_* roles + the Ubuntu-specific tail.
  # ansible-local uploads each role_paths entry as its own directory under
  # the target's /tmp/packer-provisioner-ansible-local/roles/, so they
  # resolve by role name from playbook.yml without needing a roles/ parent.
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "ansible/roles/ubuntu_base",
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
    ]
    extra_arguments = [
      "--extra-vars",
      "target_user=${var.ssh_username}"
    ]
  }

  # Final sanity + cleanup
  provisioner "shell" {
    inline = [
      "echo '--- ubuntu24 post-install checks ---'",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled ssh",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo cloud-init clean --logs --seed || true", # drop cloud-init state so next boot is a real clone first-boot
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*", # regenerated on first boot by ubuntu_base drop-in
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
