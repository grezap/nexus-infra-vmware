variable "vm_name" {
  type        = string
  default     = "vault"
  description = "VM display name and output .vmx basename. Default `vault` -- the template; per-clone names (vault-1/2/3) are set by terraform/envs/security/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/vault"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.4.0/amd64/iso-cd/debian-13.4.0-amd64-netinst.iso"
  description = "Debian 13 netinst ISO URL. Same pin as deb13."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:0b813535dd76f2ea96eff908c65e8521512c92a0631fd41c95756ffd7d4896dc"
  description = "ISO checksum (literal sha256). Same hash as deb13 -- both pin Debian 13.4.0 netinst."
}

variable "vault_version" {
  type        = string
  default     = "1.18.4"
  description = "Vault binary version to bake. Pinnable for upgrades. Latest stable as of Phase 0.D.1 plan date; bump to current latest at build time if available."
}

variable "vault_arch" {
  type        = string
  default     = "linux_amd64"
  description = "Vault binary architecture suffix on releases.hashicorp.com. amd64 covers all current lab targets."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "vCPU per Vault node. Canon (vms.yaml lines 55-57)."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "RAM per Vault node in MB. APPROVED DEVIATION from canon vms.yaml (4 GB) -- user-approved 2026-04-29 per memory/feedback_prefer_less_memory.md (Vault on lab scale runs comfortably at 2 GB; canon will be updated post-0.D.1 to match)."
}

variable "disk_gb" {
  type        = number
  default     = 40
  description = "Disk size per node in GB. Canon (vms.yaml lines 55-57). Sufficient for OS + Vault binary + Raft data + audit logs in a lab; production would specify more."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
  # Build-time only. Phase 0.D rotates to key-only via Vault SSH CA (same
  # horizon as deb13's bootstrap password).
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
