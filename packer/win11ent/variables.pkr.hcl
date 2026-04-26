variable "vm_name" {
  type        = string
  default     = "win11ent"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/win11ent"
  description = "Absolute directory for the built template (.vmx + disks + encrypted .nvram)."
}

# ─── Licensing / ISO selection ──────────────────────────────────────────────
#
# Same product_source contract as ws2025-* (see docs/licensing.md and
# ADR-0144-windows-licensing). Win11 has no Standard/Datacenter axis — only
# the Enterprise SKU vs Enterprise Evaluation SKU, gated by image_name.
#
#   product_source = "evaluation"  → "Windows 11 Enterprise Evaluation"
#   product_source = "msdn"        → "Windows 11 Enterprise"
#
# Win11 Enterprise Evaluation is 90 days, rearm-able fewer times than Server.
# Rebuild via `make win11ent` is the canonical fix for nearing-expiry VMs.
# If a future build fails because Setup can't find the named image, run
#   dism /Get-ImageInfo /ImageFile:<sources>\install.wim
# (elevated) on the mounted ISO and update the names in win11ent.pkr.hcl.

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
  default     = "H:/VMS/ISO/Win11EnterpriseEvaluation.iso"
  description = "Absolute path to Windows 11 Enterprise *Evaluation* ISO on the build host."
}

variable "iso_checksum_evaluation" {
  type        = string
  default     = "sha256:a61adeab895ef5a4db436e0a7011c92a2ff17bb0357f58b13bbc4062e535e7b9"
  description = <<-EOT
    SHA256 of the Win11 Enterprise Evaluation ISO. Microsoft does not publish
    a hash for the eval download, so this is the local Get-FileHash baseline
    captured 2026-04-26 from H:/VMS/ISO/Win11EnterpriseEvaluation.iso.
  EOT
}

variable "iso_path_msdn" {
  type        = string
  default     = "H:/VMS/ISO/Win11Enterprise.iso"
  description = "Absolute path to Windows 11 Enterprise *retail/MSDN* ISO on the build host."
}

variable "iso_checksum_msdn" {
  type        = string
  default     = "sha256:4e38767ef4c2e984cb2b76e7924bde6ec5c59cb7f9d2fb7f9313b43940b17a0a"
  description = "SHA256 of the MSDN/retail Win11 Enterprise ISO (literal, owner-provided)."
}

variable "bootstrap_keys_file" {
  type        = string
  default     = ""
  description = <<-EOT
    Pre-Phase-0.D fallback for product_source=msdn: absolute path to an
    NTFS-ACL-locked JSON file mapping template name → {key, edition}. The
    JSON must contain a "win11ent" entry with a "key" field. Ignored when
    product_source = evaluation. Leave empty to force Vault lookup.
    Example: C:/Users/<owner>/.nexus/secrets/windows-keys.json
  EOT
}

variable "vault_addr" {
  type        = string
  default     = "https://vault.nexus.local:8200"
  description = "Vault endpoint for MSDN key retrieval (post-Phase-0.D)."
}

# ─── Hardware ───────────────────────────────────────────────────────────────
# Win11 minimum is 4 GB RAM / 64 GB disk + TPM 2.0 + Secure Boot. We allocate
# 8 GB / 80 GB to leave headroom for the .NET 10 SDK install, WinAppSDK
# runtime, and a future winget cache. Clones can be shrunk via modules/vm/.

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "disk_gb" {
  type    = number
  default = 80
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
