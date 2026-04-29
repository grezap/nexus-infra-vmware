/*
 * vault — NexusPlatform Vault cluster node template (Phase 0.D.1)
 *
 * 3 instances of this template clone into a 3-node Raft cluster (vault-1,
 * vault-2, vault-3) on the foundation tier. Per nexus-platform-plan/
 * docs/infra/vms.yaml lines 55-57 + MASTER-PLAN.md line 188:
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as deb13)
 *   - 2 vCPU, 2 GB RAM (DEVIATION FROM CANON: vms.yaml says 4 GB; user-
 *     approved 2026-04-29 pre-Phase-0.D.1 — Vault on lab scale runs
 *     comfortably at 2 GB; vms.yaml will be updated post-0.D.1 to match
 *     observed-sufficient sizing per memory/feedback_prefer_less_memory.md
 *     and feedback_master_plan_authority.md)
 *   - 40 GB disk (canon)
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service); ethernet1 =
 *     VMnet10 (cluster backplane)
 *
 * Build-time vs clone-time:
 *   - Build-time (this template): single NAT NIC for apt fetch, then
 *     `vmx_remove_ethernet_interfaces = true` strips it. Vault binary is
 *     downloaded + verified + extracted to /usr/local/bin/vault. systemd
 *     unit, vault user, /opt/vault/data, base config TEMPLATE all baked.
 *   - Clone-time (terraform/modules/vm): scripts/configure-vm-nic.ps1
 *     writes ethernet0 (VMnet11) + ethernet1 (VMnet10) post-clone.
 *   - First-boot (vault.service ExecStartPre): reads /etc/hostname (set by
 *     Terraform clone-time hostname provisioner OR persisted via cloud-init),
 *     maps vault-1/2/3 -> 192.168.10.121/.122/.123 for the VMnet10 NIC,
 *     writes /etc/systemd/network/10-vmnet10.network, restarts
 *     systemd-networkd, then renders /etc/vault.d/vault.hcl from the
 *     baked template, then starts vault.
 *
 * Self-signed TLS bootstrap is regenerated PER-CLONE at first boot using
 * the clone's actual hostname + IP. Phase 0.D.2 reissues from the Vault
 * PKI engine once that's bootstrapped.
 *
 * Build:   make vault   (or `pwsh -File scripts\foundation.ps1` is foundation;
 *                        for vault use `cd packer/vault; packer build .`)
 * See:     docs/vault.md, docs/handbook.md §2
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
source "vmware-iso" "vault" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  # ISO (same Debian 13.4.0 pin as deb13)
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # Hardware (per vms.yaml lines 55-57; RAM = approved deviation)
  guest_os_type = "debian12-64" # Workstation catalog lags; compatible with Debian 13
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

  # Single NAT NIC at build time — Terraform attaches the real dual-NIC
  # config (VMnet11 + VMnet10) at clone time via modules/vm/.
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

  # SSH (build-time creds same as deb13 — Phase 0.D rotates these to Vault SSH CA)
  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  # Strip all ethernet*.* lines so Terraform's modules/vm can write the
  # dual-NIC config cleanly post-clone.
  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "vault cluster node template (Phase 0.D.1) — built by Packer; Vault ${var.vault_version}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + install Vault + apply shared roles ───────────────
build {
  name    = "vault"
  sources = ["source.vmware-iso.vault"]

  # Stage static config files the shared roles + vault role expect
  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  # Settle + install Ansible on-box
  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq"
    ]
  }

  # Apply the shared nexus_* roles + the vault_node tail.
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "ansible/roles/vault_node",
    ]
    extra_arguments = [
      "--extra-vars",
      "target_user=${var.ssh_username} vault_version=${var.vault_version} vault_arch=${var.vault_arch}"
    ]
  }

  # Final sanity + cleanup
  provisioner "shell" {
    inline = [
      "echo '--- vault post-install checks ---'",
      "test -x /usr/local/bin/vault",
      "/usr/local/bin/vault version",
      "systemctl is-enabled vault",
      "systemctl is-enabled vault-firstboot",
      "test -d /opt/vault/data",
      "test -d /etc/vault.d",
      "id vault",
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
