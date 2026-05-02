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
  description = "Directory Services Restore Mode (DSRM) administrator password used by Install-ADDSForest. Default placeholder is >=14 chars to satisfy 0.D.5 password policy (MinPasswordLength=14). Real lab uses Vault-generated 24-char value via `vault kv put nexus/foundation/dc-nexus/dsrm password=$(openssl rand -base64 24)` then `terraform apply` (the dc_rotate_bootstrap_creds overlay syncs KV -> AD)."
  type        = string
  default     = "NexusDSRMBootstrap!2026"
  sensitive   = true
}

variable "local_administrator_password" {
  description = "Password to set on the built-in Administrator account before Install-ADDSForest runs. The local Administrator becomes the domain Administrator on forest creation; Install-ADDSForest refuses to promote when its password is blank (sysprep wipes the unattend-provided password on every clone). Default placeholder is >=14 chars to satisfy 0.D.5 MinPasswordLength=14; rotate via Vault KV + dc_rotate_bootstrap_creds overlay."
  type        = string
  default     = "NexusLocalAdminBootstrap!2026"
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
  description = "MinPasswordLength on the Default Domain Policy. Bumped 12 -> 14 at Phase 0.D.5 close-out -- Vault now generates 24-char creds via the nexus-ad-rotated password policy (covers svc-vault-ldap + svc-vault-smoke + svc-demo-rotated) AND the foundation env's dc_rotate_bootstrap_creds overlay rotates DSRM + domain Administrator + nexusadmin to KV-generated 24-char values when triggered. Existing AD passwords don't retroactively re-validate; the policy applies to future password writes only."
  type        = number
  default     = 14
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
# (per nexus-platform-plan/docs/infra/vms.yaml lines 55-57). Default true
# (changed from false on 2026-05-01 after a foundation apply -Vars enable_vault_ad_integration=true
#  -- without also passing enable_vault_dhcp_reservations=true -- destroyed
#  the previously-written reservations as drift, bouncing all 3 Vault VMs
#  into the dynamic pool and breaking the entire Vault cluster + smoke gate).
# Operators who genuinely don't want gateway reservations (foundation-only
# deploys with no Vault) can opt out with -Vars enable_vault_dhcp_reservations=false.

variable "enable_vault_dhcp_reservations" {
  description = "Toggle: write dhcp-host reservations on nexus-gateway pinning vault-1/2/3 MACs to canonical VMnet11 IPs (192.168.70.121/.122/.123 per nexus-platform-plan/docs/infra/vms.yaml). MUST be true before applying envs/security/, otherwise the Vault clones DHCP into the dynamic pool and the cluster's canonical IPs are wrong. Default true (changed 2026-05-01: false-default trap silently destroys reservations on partial apply)."
  type        = bool
  default     = true
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

# ─── Phase 0.D.3 — Vault LDAP/AD integration (foundation side) ───────────
# Foundation's role is to create the AD objects Vault needs:
#   - svc-vault-ldap     : bind account for auth/ldap + secrets/ldap engines
#   - svc-vault-smoke    : test account for end-to-end smoke login probe
#   - svc-demo-rotated   : demo account whose pwd Vault will rotate
#   - 3 AD groups for Vault role mapping (admins, operators, readers)
# Bind credentials get written to $HOME/.nexus/vault-ad-bind.json on the
# build host (mirrors vault-init.json shape) so envs/security can pick
# them up without a shared state backend (pre-Phase-0.E Consul KV).

variable "enable_vault_ad_integration" {
  description = "Master toggle: create AD objects (svc accounts + groups) for Vault LDAP integration. Default true (changed from false on 2026-05-01 after partial-apply landmine -- a foundation apply WITHOUT this var on a lab that had previously enabled it would treat the AD objects as drift and DESTROY svc-vault-ldap + svc-vault-smoke + svc-demo-rotated + the 3 security groups + the OU=ServiceAccounts ACL delegation, breaking the entire Vault LDAP integration in seconds. Same gotcha class as enable_vault_dhcp_reservations -- canonized in memory/feedback_terraform_partial_apply_destroys_resources.md). Operators with foundation-only deploys (no Vault) opt out via -Vars enable_vault_ad_integration=false."
  type        = bool
  default     = true
}

variable "enable_vault_ad_bind_account" {
  description = "Toggle: create svc-vault-ldap in OU=ServiceAccounts and write bind cred JSON. Default true (gated under enable_vault_ad_integration)."
  type        = bool
  default     = true
}

variable "enable_vault_ad_bind_rotate_password" {
  description = "Toggle: rotate the svc-vault-ldap password on this apply (otherwise password is set ONLY on first creation, to avoid desyncing the bindpass that envs/security cached). Default false; set true for explicit operator-time rotation, then re-apply envs/security to pick up the new bindpass."
  type        = bool
  default     = false
}

variable "enable_vault_ad_bind_acl_delegation" {
  description = "Toggle: delegate the AD ACEs Vault's secrets/ldap engine needs to rotate passwords on accounts in OU=ServiceAccounts. Per HashiCorp KB, the bind account must hold (a) Reset Password extended right, (b) Change Password extended right, (c) Read+Write Property on userAccountControl -- all on user objects under the OU, via inheritance. Without this, `vault write -force ldap/rotate-role/<name>` fails with LDAP code 50 INSUFF_ACCESS_RIGHTS. Default true (gated under enable_vault_ad_integration). Set false only if you've delegated equivalents through GPO/native AD tooling."
  type        = bool
  default     = true
}

variable "enable_vault_ad_groups" {
  description = "Toggle: create AD security groups nexus-vault-admins, nexus-vault-operators, nexus-vault-readers in OU=Groups; add nexusadmin to nexus-vault-admins. Default true (gated under enable_vault_ad_integration)."
  type        = bool
  default     = true
}

variable "enable_vault_ad_demo_rotated_account" {
  description = "Toggle: create svc-demo-rotated in OU=ServiceAccounts (target of Vault's secrets/ldap static rotate-role). Default true (gated under enable_vault_ad_integration). The initial password is random; Vault rotates it to a Vault-managed value on first apply of the rotate-role overlay."
  type        = bool
  default     = true
}

variable "enable_vault_ad_smoke_account" {
  description = "Toggle: create svc-vault-smoke in OU=ServiceAccounts. The 0.D.3 smoke gate uses this account for end-to-end LDAP login probe (vault login -method=ldap), so its plaintext password lives next to the bind cred in $HOME/.nexus/vault-ad-bind.json. Default true."
  type        = bool
  default     = true
}

variable "vault_ad_bind_creds_file" {
  description = "Absolute path on the build host where vault-ad-bind.json (binddn + bindpass + smoke cred) gets written. Mirrors vault-init.json under operator-private $HOME/.nexus/. envs/security/ reads from this same path."
  type        = string
  default     = "$HOME/.nexus/vault-ad-bind.json"
}

variable "vault_ad_bind_account_name" {
  description = "samAccountName of the LDAP bind account Vault uses for auth/ldap and secrets/ldap. Lives in OU=ServiceAccounts."
  type        = string
  default     = "svc-vault-ldap"
}

variable "vault_ad_smoke_account_name" {
  description = "samAccountName of the test account used by the 0.D.3 smoke gate's vault login -method=ldap probe. Plaintext pwd persists in vault-ad-bind.json on the build host."
  type        = string
  default     = "svc-vault-smoke"
}

variable "vault_ad_demo_rotated_account_name" {
  description = "samAccountName of the demo account whose password Vault rotates via secrets/ldap static rotate-role. Lives in OU=ServiceAccounts."
  type        = string
  default     = "svc-demo-rotated"
}

variable "vault_ad_group_admins" {
  description = "AD security group whose members get the Vault `nexus-admin` policy (full sudo on all paths)."
  type        = string
  default     = "nexus-vault-admins"
}

variable "vault_ad_group_operators" {
  description = "AD security group whose members get the Vault `nexus-operator` policy (read/write on nexus/* + cert issuance via pki_int/issue/*; no sudo, no policy/auth/sys-mounts changes)."
  type        = string
  default     = "nexus-vault-operators"
}

variable "vault_ad_group_readers" {
  description = "AD security group whose members get the Vault `nexus-reader` policy (read-only on nexus/*)."
  type        = string
  default     = "nexus-vault-readers"
}

# ─── Phase 0.D.3 — AD LDAP signing relaxation (deviation) ────────────────
#
# Server 2025 ships with HKLM\SYSTEM\CurrentControlSet\Services\NTDS\
# Parameters\LDAPServerIntegrity = 2 (Require signing). Plain-LDAP/389
# simple binds from non-Windows clients (Vault's go-ldap library, OpenLDAP
# tools, JDK ldap, etc.) are rejected with LDAP Result Code 8 "Strong Auth
# Required" because they don't auto-negotiate sign-and-seal the way Windows
# clients do (System.DirectoryServices, ldp.exe, etc.).
#
# Lowering to 1 ("Negotiate") accepts simple bind while still preferring
# signed connections. This is the canonical lab-acceptable workaround for
# Vault's auth/ldap until LDAPS lands in 0.D.5. Documented as an explicit
# deviation per memory/feedback_master_plan_authority.md -- to be reverted
# in 0.D.5 once LDAPS is the canonical transport. See also
# memory/feedback_ad_ldap_simple_bind_signing.md for the full rule.

variable "enable_dc_ldap_signing_relaxed" {
  description = "Toggle: lower AD's LDAPServerIntegrity from 2 (Require signing -- default in modern Windows Server) to var.dc_ldap_server_integrity (default 1 = Negotiate). Required for plain-LDAP simple binds from non-Windows clients. Default false -- foundation deploys without 0.D.3 don't need this. Set true alongside enable_vault_ad_integration."
  type        = bool
  default     = false
}

variable "dc_ldap_server_integrity" {
  description = "Target value for HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NTDS\\Parameters\\LDAPServerIntegrity. 0 = None (accept any bind, even unsigned), 1 = Negotiate (prefer signing but accept unsigned), 2 = Require (reject unsigned -- default). Set to 1 for 0.D.3 plain-LDAP compatibility; revert to 2 in 0.D.5 when LDAPS lands."
  type        = number
  default     = 1
  validation {
    condition     = contains([0, 1, 2], var.dc_ldap_server_integrity)
    error_message = "Must be 0, 1, or 2."
  }
}

# ─── Phase 0.D.4 — Vault-KV-backed bootstrap creds ───────────────────────
#
# When this layer is enabled, the foundation env reads dsrm /
# local-administrator / nexusadmin passwords from Vault KV at
# `nexus/foundation/...` instead of from the variable defaults above.
# The plaintext defaults remain as a fallback for greenfield bring-up.
#
# Cross-env coupling:
#   - The security env's role-overlay-vault-foundation-policy.tf creates
#     the `nexus-foundation-reader` Vault policy + AppRole + seeds the
#     nexus/foundation/* paths. Foundation env reads via vault_kv_secret_v2
#     data sources authenticated by the AppRole role-id+secret-id JSON the
#     security env writes to var.vault_foundation_approle_creds_file.
#   - The CA bundle for TLS verification comes from the security env's
#     role-overlay-vault-pki-distribute.tf overlay (Phase 0.D.2 output).
#
# Operator order on a fresh lab:
#   1. foundation apply (default: enable_vault_kv_creds=false) -- bare lab
#      + AD plumbing using plaintext variable defaults.
#   2. security apply -- brings up Vault + writes approle JSON + seeds KV.
#   3. foundation apply -Vars enable_vault_kv_creds=true -- consumers now
#      read from Vault KV.
#
# Cross-ref: memory/feedback_terraform_partial_apply_destroys_resources.md
# -- once steady-state is reached, this default flips to `true`. Default
# flip lands at 0.D.4 close-out.

variable "enable_vault_kv_creds" {
  description = "Toggle: read bootstrap creds (dsrm, local_administrator, nexusadmin) from Vault KV at nexus/foundation/* instead of variable defaults. Default true (flipped from false at 0.D.4 close-out per feedback_terraform_partial_apply_destroys_resources.md -- defaults reflect steady state, opt-out is the explicit override). Set false on greenfield bring-up: foundation apply -Vars enable_vault_kv_creds=false runs first using plaintext defaults; then security apply seeds Vault; then foundation apply (no override) consumes from Vault."
  type        = bool
  default     = true
}

variable "vault_kv_mount_path" {
  description = "Mount path for the KV-v2 secrets engine. Per MASTER-PLAN.md s 0.D goal: nexus/* paths. Mirrors envs/security/var.vault_kv_mount_path."
  type        = string
  default     = "nexus"
}

variable "vault_foundation_approle_creds_file" {
  description = "Path on the build host where envs/security/role-overlay-vault-foundation-approle.tf writes the AppRole role-id + secret-id JSON. Foundation env's `provider \"vault\"` block reads this at plan/apply time via Terraform's pathexpand() -- which resolves `~/` to HOME but does NOT substitute `$HOME`. Default uses `~/.nexus/...` form for that reason. Resolves to the same physical file as the security env's `$HOME/.nexus/vault-foundation-approle.json` (which is PowerShell-side and uses ExpandString)."
  type        = string
  default     = "~/.nexus/vault-foundation-approle.json"
}

variable "vault_ca_bundle_path" {
  description = "Path on the build host to the Vault PKI root CA bundle (envs/security/role-overlay-vault-pki-distribute.tf output). Used by the foundation env's `provider \"vault\"` block as ca_cert_file -- enables TLS verification without VAULT_SKIP_VERIFY. Same `~/` rationale as vault_foundation_approle_creds_file -- pathexpand handles tilde, not $HOME."
  type        = string
  default     = "~/.nexus/vault-ca-bundle.crt"
}

variable "enable_vault_kv_ad_writeback" {
  description = "Toggle: when the dc_vault_ad_bind / dc_vault_ad_smoke overlays generate a fresh random pwd for an AD account, ALSO write that pwd to Vault KV at nexus/foundation/ad/<account>. Default true. Set false to keep KV as a read-only mirror (e.g. when iterating on the bind/smoke overlays without a Vault cluster up). When false, the legacy JSON-file write at vault_ad_bind_creds_file remains canonical."
  type        = bool
  default     = true
}

# ─── Phase 0.D.5 — bootstrap cred rotation (KV -> AD sync) ───────────────
#
# After 0.D.5's MinPasswordLength=14 bump, the DSRM + domain Administrator
# + nexusadmin passwords need to be >=14 chars. The dc_rotate_bootstrap_creds
# overlay reads the current values from Vault KV (nexus/foundation/...) and
# pushes them to AD via:
#   - DSRM:                 ntdsutil "set dsrm password" "reset password on server null" "<pwd>" "q" "q"
#   - domain Administrator: Set-ADAccountPassword -Identity Administrator -Reset -NewPassword
#   - nexusadmin:           Set-ADAccountPassword -Identity nexusadmin    -Reset -NewPassword
#
# Triggers on a sha256 hash of the three creds combined; whenever the
# operator runs `vault kv put nexus/foundation/dc-nexus/dsrm password=...`
# (or the other paths), the data source picks up the new value, the hash
# changes, and the overlay re-runs to push the new pwd to AD.
#
# Default true so KV becomes the canonical source of truth; set false if
# operator manages AD pwds outside of Vault.

variable "enable_dc_rotate_bootstrap_creds" {
  description = "Toggle: sync DSRM + domain Administrator + nexusadmin passwords from Vault KV into live AD whenever KV values change. Default true. Requires enable_dc_promotion=true + enable_vault_kv_creds=true. Set false to manage AD pwds outside Vault."
  type        = bool
  default     = true
}

# ─── Phase 0.D.5 — GMSA scaffolding ──────────────────────────────────────
#
# Group Managed Service Accounts (GMSAs) replace traditional svc-account
# passwords on Windows services with managed accounts whose passwords are
# auto-rotated by AD (default 30-day cadence; configurable). Each GMSA
# can be retrieved by ONLY the computer accounts in its
# PrincipalsAllowedToRetrieveManagedPassword list.
#
# Phase 0.D.5 scope: scaffold-only. KDS root key (one-time per forest;
# enables GMSA infrastructure) + sample GMSA `gmsa-nexus-demo` + AD group
# `nexus-gmsa-consumers` for the principals-allowed list. NO actual
# consumers yet (lab has no SQL Server / IIS / scheduled-task workload
# that needs GMSA today). Real consumers land when the data env
# (02-sqlserver) deploys.

variable "enable_dc_gmsa" {
  description = "Master toggle: scaffold GMSA infrastructure (KDS root key + AD group + sample GMSA). Default true. Set false to skip GMSA setup entirely (e.g. iterating on other 0.D.5 deliverables)."
  type        = bool
  default     = true
}

variable "enable_dc_gmsa_kds_root" {
  description = "Toggle: add the KDS root key on the forest (Add-KdsRootKey). One-time per forest. Idempotent via Get-KdsRootKey probe. Default true. The KDS root key is the cryptographic seed AD uses to derive every GMSA password; without it, New-ADServiceAccount fails."
  type        = bool
  default     = true
}

variable "enable_dc_gmsa_demo_account" {
  description = "Toggle: create the sample GMSA `gmsa-nexus-demo$` in OU=ServiceAccounts as a placeholder + smoke probe target. Default true. Real GMSA consumers (SQL Server svc account etc.) land when the data env deploys; this entry just proves the infrastructure works."
  type        = bool
  default     = true
}

variable "gmsa_demo_account_name" {
  description = "samAccountName of the sample GMSA (without the trailing $; AD adds it automatically because GMSAs are computer accounts). Default 'gmsa-nexus-demo'."
  type        = string
  default     = "gmsa-nexus-demo"
}

variable "gmsa_consumers_group" {
  description = "AD security group whose members are permitted to retrieve the sample GMSA's password (PrincipalsAllowedToRetrieveManagedPassword). Default 'nexus-gmsa-consumers'. Future Windows servers needing GMSA creds get added to this group."
  type        = string
  default     = "nexus-gmsa-consumers"
}

# ─── Phase 0.D.5 — nexusadmin membership remediation ─────────────────────
#
# Diagnostic finding 2026-05-02: nexusadmin is NOT in Domain Admins or
# Enterprise Admins on the live DC, despite the dc_nexus_promote v4
# remediation block intending to add it ("Add-ADGroupMember -Identity
# 'Domain Admins' -Members nexusadmin"). The chained semicolon-separated
# one-liner in v4's promote script likely silently failed at this step.
# Most AD operations to date have worked because nexusadmin is in
# Builtin\Administrators which gives effective DC control -- but
# Add-KdsRootKey (and presumably some other cmdlets) check for explicit
# Domain/Enterprise Admins membership and reject otherwise.
#
# This overlay idempotently asserts nexusadmin's required group
# memberships using the domain Administrator's credentials (read from
# Vault KV at nexus/foundation/dc-nexus/local-administrator). It runs
# before any overlay that depends on Domain/Enterprise Admins privileges
# (dc_gmsa_kds_root, dc_rotate_bootstrap_creds when targeting Domain Admin
# accounts, future Vault Agent + Transit overlays).
#
# NOT in scope: Schema Admins (much wider blast radius; only needed for
# schema modifications which 0.D.* doesn't do).

variable "enable_dc_nexusadmin_membership" {
  description = "Toggle: idempotently assert nexusadmin's membership in Domain Admins + Enterprise Admins via the domain Administrator's credentials (read from Vault KV). Default true. Restores the intended state from dc_nexus_promote v4 that silently failed during the original promotion. Required for Add-KdsRootKey and other Enterprise-Admins-gated cmdlets used in 0.D.5+."
  type        = bool
  default     = true
}

variable "dc_nexusadmin_required_groups" {
  description = "AD groups that nexusadmin must be a member of for the foundation env's overlays to succeed. Default ['Domain Admins', 'Enterprise Admins']. Schema Admins NOT included (out of scope). Order matters: groups added in list order."
  type        = list(string)
  default     = ["Domain Admins", "Enterprise Admins"]
}
