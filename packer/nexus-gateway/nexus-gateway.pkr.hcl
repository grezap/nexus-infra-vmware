/*
 * nexus-gateway — NexusPlatform lab edge router (VM #0)
 *
 * Debian 13 minimal on VMware Workstation. Three NICs:
 *   NIC0 — Bridged (physical LAN; internet egress path)
 *   NIC1 — VMnet11 (192.168.70.1/24 — gateway for lab VMs)
 *   NIC2 — VMnet10 (192.168.10.1/24 — backplane visibility)
 *
 * Role: nftables masquerade · dnsmasq DHCP (.200-.250) + DNS forwarder · chrony NTP.
 *
 * Build:   make gateway
 * Apply:   make gateway-apply
 * See:     docs/nexus-gateway.md
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
source "vmware-iso" "nexus-gateway" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  # ISO
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # Hardware
  guest_os_type = "debian12-64" # Workstation catalog lags; 12-64 is compatible with Debian 13
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

  # Three NICs — mapped by Terraform later; Packer builds the single-NIC
  # template and Terraform adds the extra adapters per instantiation.
  network_adapter_type = "vmxnet3"
  network              = "nat" # build-time: use VMware NAT for apt fetch
  # NB: we keep `network = "nat"` for the BUILD (gets internet for apt/ansible),
  # but the elsudano/vmworkstation v2.0.1 SDK panics cloning a NAT-typed NIC
  # (maps connectionType=nat → vmnet8 internally, then vmrest rejects sending
  # both). After build, strip ethernet0.* and replace with a custom-type NIC
  # on vmnet1 so the provider's clone-then-recreate dance works. See
  # README.md § "Known issues" and scripts/normalize-template-nic.ps1.

  # Firmware / hardware revision
  version = "20" # WS 17+ hw version
  # Keep BIOS rather than EFI for simpler preseed on Debian 13.

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

  # SSH — Packer waits until the installed system comes up and accepts SSH
  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  # Graceful shutdown so the template is clean
  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  # Headless build — no console window pops up.
  headless = true

  # Leave the VM as a template (do not compact — Terraform linked-clones will handle it)
  skip_compaction = false

  # Strip all ethernet*.* lines from the finished .vmx. Rationale:
  # elsudano/vmworkstation v2.0.1 + vmrest 17.6.x hit a regression (issue #28
  # in the provider repo) where cloning a template whose .vmx contains any
  # ethernetN.connectionType = "nat|bridged|..." lines fails with
  #   StatusCode:400 Code:121 "Redundant parameter: vmnet8 for this operation"
  # Terraform's null_resource.configure_nics rewrites all three NICs post-clone
  # anyway (see scripts/configure-gateway-nics.ps1), so we lose nothing by
  # starting from zero ethernet entries.
  vmx_remove_ethernet_interfaces = true

  # Metadata for the resulting .vmx
  vmx_data = {
    "annotation"           = "nexus-gateway template (Phase 0.B.1) — built by Packer"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + hand off to Ansible for role config ──────────────
build {
  name    = "nexus-gateway"
  sources = ["source.vmware-iso.nexus-gateway"]

  # Copy static config files the role expects
  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/dnsmasq.conf"
    destination = "/tmp/dnsmasq.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  # Wait for cloud-init/systemd to settle before Ansible hits the box
  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites (ansible-local provisioner runs ansible-playbook on-box)...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible"
    ]
  }

  # Apply the nexus_gateway Ansible role
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths    = ["ansible/roles/nexus_gateway"]
    extra_arguments = [
      "--extra-vars",
      "target_user=${var.ssh_username}"
    ]
  }

  # Final sanity + cleanup
  provisioner "shell" {
    inline = [
      "echo '--- nexus-gateway post-install checks ---'",
      "systemctl is-enabled nftables",
      "systemctl is-enabled dnsmasq",
      "systemctl is-enabled chrony",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  # Manifest — records sha + timestamp so Terraform can pin to this build
  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
