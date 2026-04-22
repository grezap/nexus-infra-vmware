variable "vm_name" {
  type        = string
  default     = "deb13"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/deb13"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.4.0/amd64/iso-cd/debian-13.4.0-amd64-netinst.iso"
  description = "Debian 13 netinst ISO URL. Pinned to current stable point release."
}

variable "iso_checksum" {
  type = string
  # Pinned sha256 of debian-13.4.0-amd64-netinst.iso (authoritative source:
  # cdimage.debian.org/debian-cd/13.4.0/amd64/iso-cd/SHA256SUMS, 2026-04).
  # Same hash as nexus-gateway — both pin to Debian 13.4.0 netinst.
  default     = "sha256:0b813535dd76f2ea96eff908c65e8521512c92a0631fd41c95756ffd7d4896dc"
  description = "ISO checksum (literal sha256 hash)."
}

variable "cpus" {
  type    = number
  default = 2
  # Slightly more generous than gateway — most deb13 clones will run workloads
  # heavier than an edge router. Terraform callers of modules/vm/ can override.
}

variable "memory_mb" {
  type = number
  # Same rationale as nexus-gateway: Debian 13's installer needs ≥ 780 MB at
  # build time or drops into low-memory mode (preseed.cfg fetch disabled).
  # Runtime callers typically shrink back to 1024-2048 MB.
  default = 1024
}

variable "disk_gb" {
  type    = number
  default = 10
  # 10 GB gives clones room to grow without `disk grow` gymnastics. Single-file
  # growable VMDK starts thin — the build artifact is typically ~1.5 GB.
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
  # to key-only via Vault SSH CA.
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
