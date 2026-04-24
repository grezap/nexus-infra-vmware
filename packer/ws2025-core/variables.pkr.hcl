variable "vm_name" {
  type        = string
  default     = "ws2025-core"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/ws2025-core"
  description = "Absolute directory for the built template (.vmx + disks)."
}

# ─── Licensing / ISO selection ──────────────────────────────────────────────
#
# See docs/licensing.md for the full story. Two build modes are supported:
#
#   product_source = "evaluation"   (default — public/cloner path)
#     → ISO: WindowsServer2025Evaluation.iso (separate download from MS eval center)
#     → Image name: "Windows Server 2025 Standard Evaluation" (Core = no Desktop Experience)
#     → No product key — 180-day eval, rearm-able
#
#   product_source = "msdn"         (owner path, requires MSDN subscription)
#     → ISO: WindowsServer2025.iso (retail)
#     → Image name: "Windows Server 2025 Standard"
#     → Key from Vault (post-Phase-0.D) or from bootstrap_keys_file JSON (Phase-0.B)
#
# The locals block in ws2025-core.pkr.hcl picks iso_path/iso_checksum/image_name
# based on product_source, so the build command is symmetric:
#
#   packer build .                          # defaults to evaluation
#   packer build -var product_source=msdn . # owner flow

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
  type = string
  # Computed locally 2026-04-23 against H:/VMS/ISO/WindowsServer2025Evaluation.iso.
  # Microsoft does not publish an authoritative hash on the Evaluation Center page,
  # so this is pinned to what was downloaded on this host — rotate on re-download.
  default     = "sha256:7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51"
  description = "SHA256 of the Evaluation ISO (literal)."
}

variable "iso_path_msdn" {
  type        = string
  default     = "H:/VMS/ISO/WindowsServer2025.iso"
  description = "Absolute path to Windows Server 2025 *retail/MSDN* ISO on the build host."
}

variable "iso_checksum_msdn" {
  type = string
  # Computed locally 2026-04-23 against H:/VMS/ISO/WindowsServer2025.iso (MSDN download).
  default     = "sha256:2d099c70de0317197b6f3906d957504f656ef8b05ba6e1e92a17ff963d5cdf89"
  description = "SHA256 of the MSDN/retail ISO (literal)."
}

variable "bootstrap_keys_file" {
  type        = string
  default     = ""
  description = <<-EOT
    Pre-Phase-0.D fallback for product_source=msdn: absolute path to an
    NTFS-ACL-locked JSON file mapping template name → {key, edition}.
    See docs/licensing.md §"Pre-Phase-0.D bootstrap". Ignored when
    product_source = evaluation. Leave empty to force Vault lookup
    (which will fail before Vault exists — use the bootstrap file until then).
    Example: C:/Users/<owner>/.nexus/secrets/windows-keys.json
  EOT
}

variable "vault_addr" {
  type        = string
  default     = "https://vault.nexus.local:8200"
  description = "Vault endpoint for MSDN key retrieval (product_source=msdn, post-Phase-0.D)."
}

# ─── Hardware ───────────────────────────────────────────────────────────────

variable "cpus" {
  type    = number
  default = 4
  # Windows Setup + sysprep is CPU-bound; 4 vCPU shaves ~10 min vs 2.
}

variable "memory_mb" {
  type    = number
  default = 4096
  # WS2025 Core Setup + VMware Tools install fit in 4 GB comfortably.
  # Clones can be shrunk to 2048 via modules/vm/ post-template.
}

variable "disk_gb" {
  type    = number
  default = 60
  # WS2025 Core install footprint ~10 GB; 60 GB leaves room for role overlays
  # (SQL Server install media, windows_exporter, swap/pagefile, update cache).
}

# ─── Credentials (build-time only; Ansible/SSH/WinRM rotated out later) ────

variable "admin_username" {
  type    = string
  default = "nexusadmin"
}

variable "admin_password" {
  type      = string
  default   = "NexusPackerBuild!1"
  sensitive = true
  # Unattend.xml sets this as the local Administrator password AND creates
  # nexusadmin with the same password. WinRM uses it during Packer build.
  # Rotated to Vault-issued credentials in Phase 0.D.
}

variable "winrm_timeout" {
  type    = string
  default = "2h"
  # Setup → FirstLogonCommands → WinRM listener can take 20-30 min on first
  # boot depending on ISO bit-rate. 2h is paranoid-safe.
}
