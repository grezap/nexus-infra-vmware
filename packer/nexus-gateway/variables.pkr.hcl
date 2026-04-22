variable "vm_name" {
  type        = string
  default     = "nexus-gateway"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/nexus-gateway"
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
  # Update only when iso_url changes. Verify via:
  #   curl -sL https://cdimage.debian.org/debian-cd/13.4.0/amd64/iso-cd/SHA256SUMS | grep netinst
  # A literal hash is preferred over 'file:https://.../SHA256SUMS' because
  # Debian archives old point releases, which would 404 the SHA file.
  default     = "sha256:0b813535dd76f2ea96eff908c65e8521512c92a0631fd41c95756ffd7d4896dc"
  description = "ISO checksum (literal sha256 hash)."
}

variable "cpus" {
  type    = number
  default = 1
}

variable "memory_mb" {
  type    = number
  default = 512
}

variable "disk_gb" {
  type    = number
  default = 4
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
  # Used only during Packer build. Ansible rotates to SSH-key-only in final provisioning.
}

variable "boot_wait" {
  type    = string
  default = "5s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
