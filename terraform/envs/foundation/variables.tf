variable "template_vmx_path" {
  description = "Absolute path to the Packer-built ws2025-desktop template .vmx (Phase 0.B.5 output). Both foundation VMs clone from this single template."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/ws2025-desktop/ws2025-desktop.vmx"
}

variable "vm_output_dir_root" {
  description = "Tier directory under which each foundation VM gets its own subdir. Tier convention: 10-core/ holds always-on infrastructure (foundation + later Vault, Consul)."
  type        = string
  default     = "H:/VMS/NexusPlatform/10-core"
}

variable "vnet" {
  description = "VMware network name. Foundation always rides VMnet11 (lab subnet 192.168.70.0/24) where nexus-gateway serves DHCP/DNS/NAT."
  type        = string
  default     = "VMnet11"
}

variable "mac_dc_nexus" {
  description = "Static MAC for dc-nexus. Smoke/lab range (00:50:56:3F:00:20-2F); :20-:24 used by per-template smoke harnesses, :25 = dc-nexus."
  type        = string
  default     = "00:50:56:3F:00:25"
}

variable "mac_nexus_admin_jumpbox" {
  description = "Static MAC for nexus-jumpbox. Same smoke/lab range; :26 follows :25."
  type        = string
  default     = "00:50:56:3F:00:26"
}

# ─── Phase 0.C.2 — AD DS role overlay on dc-nexus ────────────────────────

variable "enable_dc_promotion" {
  description = "Toggle: run the dc-nexus AD DS role overlay (rename + Install-ADDSForest). True by default because foundation = always-on plumbing. Set to false to land bare clones only (e.g. iterating on the VM clone path without re-running multi-minute promotion)."
  type        = bool
  default     = true
}

variable "enable_gateway_dns_forward" {
  description = "Toggle: write a `server=<ad_domain>/<dc-nexus-ip>` entry to nexus-gateway's dnsmasq.d/ at apply time. Required for VMnet11 hosts to resolve the AD domain. Defaults to true; depends on dc_nexus_wait_promoted, so this becomes a no-op when enable_dc_promotion=false."
  type        = bool
  default     = true
}

variable "ad_domain" {
  description = "Active Directory FQDN for the foundation forest. RFC-2606 friendly default (`.lab` is reserved). Only meaningful when enable_dc_promotion=true."
  type        = string
  default     = "nexus.lab"
}

variable "ad_netbios" {
  description = "NetBIOS name for the AD forest. Must be <=15 chars, uppercase by convention. Only meaningful when enable_dc_promotion=true."
  type        = string
  default     = "NEXUS"
  validation {
    condition     = length(var.ad_netbios) <= 15
    error_message = "NetBIOS name must be 15 characters or fewer."
  }
}

variable "dsrm_password" {
  description = "Directory Services Restore Mode (DSRM) administrator password used by Install-ADDSForest. Pre-Phase-0.D this lives plaintext in tfvars / defaults; Vault-backed in Phase 0.D. Does not need to match the build-time nexusadmin password."
  type        = string
  default     = "NexusDSRM!1"
  sensitive   = true
}

variable "local_administrator_password" {
  description = "Password to set on the built-in Administrator account before Install-ADDSForest runs. The local Administrator becomes the domain Administrator on forest creation; Install-ADDSForest refuses to promote when its password is blank (sysprep wipes the unattend-provided password on every clone). Pre-Phase-0.D plaintext default; Vault-backed in Phase 0.D."
  type        = string
  default     = "NexusAdmin!1"
  sensitive   = true
}

variable "nexusadmin_password" {
  description = "Password to set on the migrated `nexusadmin` AD user post-promotion. Install-ADDSForest converts the local SAM into the AD database; the local `nexusadmin` survives as a domain user but its password is wiped, so we reset it back to the build-time bootstrap value. Same Vault-rotation horizon as dsrm_password and local_administrator_password."
  type        = string
  default     = "NexusPackerBuild!1"
  sensitive   = true
}

variable "dc_promotion_timeout_minutes" {
  description = "Per-step timeout for waiting on rename-reboot and post-promotion AD DS bootstrap. Tune up if the build host is slow. Also reused by jumpbox-domain-join's wait_rejoined poll."
  type        = number
  default     = 15
}

# ─── Phase 0.C.3 — jumpbox domain-join overlay ───────────────────────────

variable "enable_jumpbox_domain_join" {
  description = "Toggle: domain-join nexus-jumpbox to var.ad_domain via Add-Computer. Default true. Implicitly depends on enable_dc_promotion=true via depends_on null_resource.dc_nexus_verify -- if the DC isn't promoted, this is a no-op. Set to false to keep the jumpbox in workgroup mode (e.g. iterating on the DC overlay independently)."
  type        = bool
  default     = true
}
