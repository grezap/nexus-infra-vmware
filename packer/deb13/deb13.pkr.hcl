/*
 * deb13 — NexusPlatform generic Debian 13 base template (Phase 0.B.2)
 *
 * Minimal Debian 13 VM image. Future VMs (Vault, Postgres, Kafka, Mongo,
 * Redis, ClickHouse, StarRocks, MinIO, Swarm workers, Spark, …) clone this
 * template and overlay their role-specific Ansible/config on top.
 *
 * Differences vs. nexus-gateway:
 *   - Single NIC at clone time (VMnet11, DHCP from nexus-gateway's dnsmasq)
 *   - NO router packages (no dnsmasq, no masquerade, no ip_forward)
 *   - chrony is a CLIENT pointing at 192.168.70.1 (the gateway)
 *   - nftables baseline is deny-inbound + allow-SSH-from-VMnet11 only
 *   - NIC rename uses OriginalName=en* (MAC-agnostic) so any clone works
 *
 * Build:   make deb13
 * Smoke:   make deb13-smoke
 * See:     docs/deb13.md
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

# ─── Source: Debian 13 netinst, VMware Workstation builder ────────────────
source "vmware-iso" "deb13" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  # ISO
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # Hardware
  guest_os_type = "debian12-64" # Workstation catalog lags; compatible with Debian 13
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

  # Single NIC — Terraform attaches the real VMnet11 NIC at clone time via
  # modules/vm/. Build-time NAT is just for apt fetch.
  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20" # WS 17+ hw version

  # Preseed delivered via Packer's HTTP server
  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
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
  # NIC entry post-clone (same pattern as nexus-gateway, keeps the template
  # NIC-config-free so any caller can pick its own network + MAC).
  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "deb13 generic base template (Phase 0.B.2) — built by Packer"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + hand off to Ansible for role config ──────────────
build {
  name    = "deb13"
  sources = ["source.vmware-iso.deb13"]

  # Stage static config files the role expects
  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  # Settle + install Ansible on-box (ansible-local runs ansible-playbook here)
  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible"
    ]
  }

  # Apply the debian_base Ansible role
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths    = ["ansible/roles/debian_base"]
    extra_arguments = [
      "--extra-vars",
      "target_user=${var.ssh_username}"
    ]
  }

  # Final sanity + cleanup
  provisioner "shell" {
    inline = [
      "echo '--- deb13 post-install checks ---'",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled ssh",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*", # regenerated on first boot
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
