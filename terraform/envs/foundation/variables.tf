variable "template_vmx_path" {
  description = "Absolute path to the Packer-built ws2025-desktop template .vmx (Phase 0.B.5 output). Both foundation VMs clone from this single template."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/ws2025-desktop/ws2025-desktop.vmx"
}

variable "vm_output_dir_root" {
  description = "Tier directory under which each foundation VM gets its own subdir. Canonical per nexus-platform-plan/docs/infra/vms.yaml: foundation tier = `01-foundation/` (always-on plumbing — DC, Vault, observability). Earlier scaffolding used `10-core/` which deviated from canon; corrected 2026-04-29 per memory/feedback_master_plan_authority.md."
  type        = string
  default     = "H:/VMS/NexusPlatform/01-foundation"
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

# ─── Phase 0.C.4 — AD DS hardening overlays ──────────────────────────────
# Each hardening concern is its own role-overlay-dc-*.tf file with its own
# enable_dc_* toggle, per memory/feedback_selective_provisioning.md. All
# overlays depend on null_resource.dc_nexus_verify, so they're no-ops when
# enable_dc_promotion=false.

# OU layout + jumpbox move
variable "enable_dc_ous" {
  description = "Toggle: create OU=Servers, OU=Workstations, OU=ServiceAccounts, OU=Groups under DC=nexus,DC=lab and move nexus-jumpbox from CN=Computers into OU=Servers. dc-nexus stays at the built-in CN=Domain Controllers (Microsoft hard rule). Default true."
  type        = bool
  default     = true
}

# Default Domain Password + Lockout Policy
variable "enable_dc_password_policy" {
  description = "Toggle: apply Default Domain Password + Lockout Policy via Set-ADDefaultDomainPasswordPolicy. NIST SP 800-63B-aligned defaults below; tune per var. Default true."
  type        = bool
  default     = true
}

variable "dc_password_min_length" {
  description = "MinPasswordLength on the Default Domain Policy. 12 matches existing bootstrap creds (NexusAdmin!1 = 12 chars); bump to 14+ in Phase 0.D when Vault generates creds."
  type        = number
  default     = 12
  validation {
    condition     = var.dc_password_min_length >= 8 && var.dc_password_min_length <= 128
    error_message = "MinPasswordLength must be between 8 and 128 (AD constraint)."
  }
}

variable "dc_lockout_threshold" {
  description = "LockoutThreshold (invalid attempts before account lockout). Must be >=5 per memory/feedback_lab_host_reachability.md -- prevents an automated probe loop with stale creds from locking out nexusadmin and breaking SSH/RDP from the build host."
  type        = number
  default     = 5
  validation {
    condition     = var.dc_lockout_threshold >= 5
    error_message = "LockoutThreshold must be >= 5 to preserve build-host reachability (per feedback_lab_host_reachability.md)."
  }
}

variable "dc_lockout_duration_minutes" {
  description = "LockoutDuration AND LockoutObservationWindow in minutes (kept equal -- AD requires duration >= observation window, and there's no operational reason for them to differ in this lab)."
  type        = number
  default     = 15
}

variable "dc_max_password_age_days" {
  description = "MaxPasswordAge in days. 0 = never expire (modern NIST stance: rotate only on suspected compromise). Pre-Vault we have no automation for clean rotation; Phase 0.D Vault re-tightens this."
  type        = number
  default     = 0
}

variable "dc_min_password_age_days" {
  description = "MinPasswordAge in days. 0 = allow immediate change (break-glass scenarios)."
  type        = number
  default     = 0
}

variable "dc_password_history_count" {
  description = "PasswordHistoryCount -- number of remembered prior passwords. AD default is 24."
  type        = number
  default     = 24
}

# Reverse DNS zone for VMnet11
variable "enable_dc_reverse_dns" {
  description = "Toggle: add the 70.168.192.in-addr.arpa reverse DNS zone (AD-integrated, secure dynamic update) on dc-nexus + PTR records for dc-nexus (.240) and nexus-jumpbox (.241). Improves log readability for AD/Kerberos operations. VMnet10 / 10.0.70.0/24 (build-host LAN) is intentionally NOT included -- not AD-relevant. Default true."
  type        = bool
  default     = true
}

# W32Time PDC authoritative source
variable "enable_dc_time_authoritative" {
  description = "Toggle: configure dc-nexus (the PDC) as authoritative time source for nexus.lab via w32tm /config /reliable:YES. Domain members inherit time from the PDC by default -- no client-side configuration needed. Default true."
  type        = bool
  default     = true
}

variable "dc_time_external_peers" {
  description = "Comma-separated NTP host list that dc-nexus syncs from. Translated to w32tm's space-separated `<host>,0x8` format internally (0x8 = SpecialInterval, recommended PDC pattern per Microsoft KB 939322). Default = four mixed-provider public peers; pivoting to gateway-as-NTP-server is a separate ticket post-0.C.4."
  type        = string
  default     = "time.cloudflare.com,time.nist.gov,pool.ntp.org,time.windows.com"
}

# ─── Phase 0.D.1 — Vault cluster gateway dnsmasq dhcp-host reservations ───
# When the security env (Vault cluster) is being deployed, the gateway needs
# per-MAC reservations so vault-1/2/3 DHCP into canonical IPs .121/.122/.123
# (per nexus-platform-plan/docs/infra/vms.yaml lines 55-57). Default false
# so existing foundation-only deploys don't touch the gateway. Set true via
# `pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_dhcp_reservations=true`
# OR drop into terraform.tfvars, OR set a default override via -var.

variable "enable_vault_dhcp_reservations" {
  description = "Toggle: write dhcp-host reservations on nexus-gateway pinning vault-1/2/3 MACs to canonical VMnet11 IPs (192.168.70.121/.122/.123 per nexus-platform-plan/docs/infra/vms.yaml). MUST be true before applying envs/security/, otherwise the Vault clones DHCP into the dynamic pool and the cluster's canonical IPs are wrong. Default false to avoid surprising existing foundation-only deploys."
  type        = bool
  default     = false
}

# Vault MAC variables -- defaults match envs/security/'s defaults so changes
# stay in sync. If you ever need to change the Vault MAC scheme, update both
# this env's variables.tf AND envs/security/variables.tf.

variable "mac_vault_1_primary" {
  description = "vault-1 primary NIC MAC (VMnet11). Used for the dnsmasq dhcp-host reservation pinning vault-1 to 192.168.70.121."
  type        = string
  default     = "00:50:56:3F:00:40"
}

variable "mac_vault_2_primary" {
  description = "vault-2 primary NIC MAC (VMnet11). Used for the dnsmasq dhcp-host reservation pinning vault-2 to 192.168.70.122."
  type        = string
  default     = "00:50:56:3F:00:41"
}

variable "mac_vault_3_primary" {
  description = "vault-3 primary NIC MAC (VMnet11). Used for the dnsmasq dhcp-host reservation pinning vault-3 to 192.168.70.123."
  type        = string
  default     = "00:50:56:3F:00:42"
}
