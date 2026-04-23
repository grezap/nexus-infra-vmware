variable "vm_name" {
  type        = string
  default     = "ubuntu24"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/ubuntu24"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type = string
  # Ubuntu 24.04.4 LTS live-server (Feb 2026 point release of the 24.04 LTS line).
  default     = "https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso"
  description = "Ubuntu 24.04 live-server ISO URL. Pinned to the current LTS point release."
}

variable "iso_checksum" {
  type = string
  # Pinned sha256 of ubuntu-24.04.4-live-server-amd64.iso (authoritative source:
  # releases.ubuntu.com/24.04/SHA256SUMS, verified 2026-04).
  default     = "sha256:e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"
  description = "ISO checksum (literal sha256 hash)."
}

variable "cpus" {
  type    = number
  default = 2
  # Same rationale as deb13 — most ubuntu24 clones will run workloads heavier
  # than the gateway. Terraform callers of modules/vm/ can override.
}

variable "memory_mb" {
  type = number
  # Ubuntu 24.04 live-server installer needs ≥ 2048 MB or Subiquity OOMs
  # partway through package install. Runtime callers typically shrink back to
  # 1024-2048 MB once the golden image is done.
  default = 2048
}

variable "disk_gb" {
  type    = number
  default = 10
  # Same sizing as deb13. Single-file growable VMDK — build artifact is ~2 GB.
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
  # Used only during Packer build. Ansible hardens sshd; Phase 0.D rotates
  # to key-only via Vault SSH CA. Must match the SHA-512 crypt hash baked
  # into http/user-data (identity.password).
}

variable "boot_wait" {
  type    = string
  default = "10s"
  # GRUB menu takes ~3-5s to render on VMware Workstation first power-on;
  # add slack so the <c> keystroke lands in the menu, not the SeaBIOS logo.
  # First build attempt with 5s never saw GRUB and timed out after 48 min.
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
  # Empirically ~13 min end-to-end on this hardware (i7 + NVMe):
  # autoinstall 9 min → reboot + cloud-init ~2 min → SSH available.
  # 20m was too tight on slow-mirror days (dpkg seeding stretched to 19 min
  # once), 30m gives slack without wasting time on genuine hangs.
}
