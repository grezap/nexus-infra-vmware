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
  default     = "https://cdimage.debian.org/debian-cd/13.0.0/amd64/iso-cd/debian-13.0.0-amd64-netinst.iso"
  description = "Debian 13 netinst ISO URL. Pinned for reproducibility."
}

variable "iso_checksum" {
  type        = string
  # Pinned sha256 of debian-13.0.0-amd64-netinst.iso. Update only when iso_url changes.
  # Fetch via: curl -sL https://cdimage.debian.org/debian-cd/13.0.0/amd64/iso-cd/SHA256SUMS | grep netinst
  default     = "file:https://cdimage.debian.org/debian-cd/13.0.0/amd64/iso-cd/SHA256SUMS"
  description = "ISO checksum (hash, or 'file:' URL to SHA256SUMS, or 'none')."
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
