variable "vm_name" {
  type        = string
  default     = "ws2025-desktop"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/ws2025-desktop"
  description = "Absolute directory for the built template (.vmx + disks)."
}

# ─── Licensing / ISO selection ──────────────────────────────────────────────
#
# Same product_source contract as ws2025-core (see docs/licensing.md). The two
# templates share the same WS2025 ISO -- only the install.wim image_name
# differs between the Core and Desktop Experience editions.
#
#   product_source = "evaluation"  → "Windows Server 2025 Standard Evaluation (Desktop Experience)"
#   product_source = "msdn"        → "Windows Server 2025 Standard (Desktop Experience)"
#
# If a future build fails because Setup can't find the named image, run
#   dism /Get-ImageInfo /ImageFile:<sources>\install.wim
# (elevated) on the mounted ISO and update the names in ws2025-desktop.pkr.hcl.

variable "product_source" {
  type        = string
  default     = "evaluation"
  description = "Activation path: 'evaluation' (public) or 'msdn' (owner)."

  validation {
    condition     = contains(["evaluation", "msdn"], var.product_source)
    error_message = "The product_source variable must be either 'evaluation' or 'msdn'."
  }
}

variable "iso_path_evaluation" {
  type        = string
  default     = "H:/VMS/ISO/WindowsServer2025Evaluation.iso"
  description = "Absolute path to Windows Server 2025 *Evaluation* ISO on the build host."
}

variable "iso_checksum_evaluation" {
  type        = string
  default     = "sha256:7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51"
  description = "SHA256 of the Evaluation ISO (literal). Same hash as ws2025-core -- shared ISO."
}

variable "iso_path_msdn" {
  type        = string
  default     = "H:/VMS/ISO/WindowsServer2025.iso"
  description = "Absolute path to Windows Server 2025 *retail/MSDN* ISO on the build host."
}

variable "iso_checksum_msdn" {
  type        = string
  default     = "sha256:2d099c70de0317197b6f3906d957504f656ef8b05ba6e1e92a17ff963d5cdf89"
  description = "SHA256 of the MSDN/retail ISO (literal). Same hash as ws2025-core -- shared ISO."
}

variable "bootstrap_keys_file" {
  type        = string
  default     = ""
  description = <<-EOT
    Pre-Phase-0.D fallback for product_source=msdn: absolute path to an
    NTFS-ACL-locked JSON file mapping template name → {key, edition}. The
    JSON must contain a "ws2025-desktop" entry with a "key" field. Ignored
    when product_source = evaluation. Leave empty to force Vault lookup.
    Example: C:/Users/<owner>/.nexus/secrets/windows-keys.json
  EOT
}

variable "vault_addr" {
  type        = string
  default     = "https://vault.nexus.local:8200"
  description = "Vault endpoint for MSDN key retrieval (post-Phase-0.D)."
}

# ─── Hardware ───────────────────────────────────────────────────────────────
# Desktop Experience needs more RAM/disk than Core: full shell + Edge + RSAT
# tools push the install footprint to ~16 GB, and the desktop session itself
# wants 4-8 GB to feel responsive when an admin RDPs in.

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 6144
  # +50% over ws2025-core. Clones can be shrunk via modules/vm/.
}

variable "disk_gb" {
  type    = number
  default = 80
  # +20 GB over Core for RSAT, GPMC, Edge, productivity tools, update cache.
}

# ─── Credentials (build-time only; rotated to Vault in Phase 0.D) ──────────

variable "admin_username" {
  type    = string
  default = "nexusadmin"
}

variable "admin_password" {
  type      = string
  default   = "NexusPackerBuild!1"
  sensitive = true
}

variable "winrm_timeout" {
  type    = string
  default = "2h"
}
