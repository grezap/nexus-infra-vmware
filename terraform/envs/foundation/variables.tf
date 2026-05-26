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

variable "mac_vault_transit_primary" {
  description = "vault-transit primary NIC MAC (VMnet11). Used for the dnsmasq dhcp-host reservation pinning vault-transit to 192.168.70.124. Phase 0.D.5.5: vault-transit is the transit auto-unseal key custodian for vault-1/2/3."
  type        = string
  default     = "00:50:56:3F:00:43"
}

# ─── Phase 0.E.1 — Swarm cluster dnsmasq dhcp-host reservations ──────────
# Same partial-apply landmine class as enable_vault_dhcp_reservations
# (memory/feedback_terraform_partial_apply_destroys_resources.md): a
# foundation apply that omits these vars on a lab that had previously
# enabled them would destroy the Swarm dhcp-host pins, clones would fall
# back into the dynamic .200-.250 pool, and the canonical .111-.113 /
# .131-.133 invariants required by nexus-infra-swarm-nomad/terraform/envs/
# swarm-nomad/ would be violated. Default true.
#
# Cross-repo dependency: the canonical IPs pinned here are consumed by
# nexus-infra-swarm-nomad/terraform/envs/swarm-nomad/. The MAC defaults
# match that env's variables.tf swarm-cluster MAC pool 1:1.

variable "enable_swarm_dhcp_reservations" {
  description = "Toggle: write dnsmasq dhcp-host reservations on nexus-gateway for the 3+3 Swarm cluster (Phase 0.E.1). Default true (steady state: lab has the swarm tier active). Set false ONLY when running a foundation-only apply on a lab that has never had the Swarm reservations -- otherwise destruction is silent."
  type        = bool
  default     = true
}

variable "mac_swarm_manager_1_primary" {
  description = "swarm-manager-1 primary NIC (VMnet11). Pinned to 192.168.70.111."
  type        = string
  default     = "00:50:56:3F:00:50"
}

variable "mac_swarm_manager_2_primary" {
  description = "swarm-manager-2 primary NIC (VMnet11). Pinned to 192.168.70.112."
  type        = string
  default     = "00:50:56:3F:00:51"
}

variable "mac_swarm_manager_3_primary" {
  description = "swarm-manager-3 primary NIC (VMnet11). Pinned to 192.168.70.113."
  type        = string
  default     = "00:50:56:3F:00:52"
}

variable "mac_swarm_worker_1_primary" {
  description = "swarm-worker-1 primary NIC (VMnet11). Pinned to 192.168.70.131."
  type        = string
  default     = "00:50:56:3F:00:53"
}

variable "mac_swarm_worker_2_primary" {
  description = "swarm-worker-2 primary NIC (VMnet11). Pinned to 192.168.70.132."
  type        = string
  default     = "00:50:56:3F:00:54"
}

variable "mac_swarm_worker_3_primary" {
  description = "swarm-worker-3 primary NIC (VMnet11). Pinned to 192.168.70.133."
  type        = string
  default     = "00:50:56:3F:00:55"
}

# ─── Phase 0.H — Kafka tier dnsmasq reservations (foundation side) ────────
# nexus-infra-kafka clones the 15 kafka VMs but the gateway is foundation's
# responsibility -- the dhcp-host reservations live here so two terraform
# repos never race on /etc/dnsmasq.d/. The 15 mac_kafka_*_primary defaults
# MUST match nexus-infra-kafka/terraform/envs/kafka/variables.tf's MAC pool
# 1:1 (00:50:56:3F:00:60-6E primaries). role-overlay-gateway-kafka-
# reservations.tf consumes these.

variable "enable_kafka_dhcp_reservations" {
  description = "Toggle: write dnsmasq dhcp-host reservations on nexus-gateway for the 15-VM Kafka tier (Phase 0.H). Default true (steady state once Phase 0.H starts). Same partial-apply-destruction landmine class as enable_swarm_dhcp_reservations -- a foundation apply WITHOUT this var on a lab that had it enabled would silently destroy the reservations + the kafka clones would lose their canonical IPs on next DHCP renew. Opt out with -Vars enable_kafka_dhcp_reservations=false ONLY on a pre-Phase-0.H lab."
  type        = bool
  default     = true
}

# Brokers (kafka-east/west, 0.H.1) -- canon vms.yaml lines 88-98.
variable "mac_kafka_east_1_primary" {
  description = "kafka-east-1 primary NIC (VMnet11). Pinned to 192.168.70.21."
  type        = string
  default     = "00:50:56:3F:00:60"
}
variable "mac_kafka_east_2_primary" {
  description = "kafka-east-2 primary NIC (VMnet11). Pinned to 192.168.70.22."
  type        = string
  default     = "00:50:56:3F:00:61"
}
variable "mac_kafka_east_3_primary" {
  description = "kafka-east-3 primary NIC (VMnet11). Pinned to 192.168.70.23."
  type        = string
  default     = "00:50:56:3F:00:62"
}
variable "mac_kafka_west_1_primary" {
  description = "kafka-west-1 primary NIC (VMnet11). Pinned to 192.168.70.24."
  type        = string
  default     = "00:50:56:3F:00:63"
}
variable "mac_kafka_west_2_primary" {
  description = "kafka-west-2 primary NIC (VMnet11). Pinned to 192.168.70.25."
  type        = string
  default     = "00:50:56:3F:00:64"
}
variable "mac_kafka_west_3_primary" {
  description = "kafka-west-3 primary NIC (VMnet11). Pinned to 192.168.70.26."
  type        = string
  default     = "00:50:56:3F:00:65"
}
# Ecosystem (schema-registry / connect / ksqldb / mm2 / rest, 0.H.3-0.H.5)
# -- canon vms.yaml lines 104-112. ksqldb-2 pinned to .98 (vms.yaml line 109
# .99 is a typo, fixed in vms.yaml at the 0.H.6 close-out canon batch).
variable "mac_kafka_schema_registry_1_primary" {
  description = "schema-registry-1 primary NIC (VMnet11). Pinned to 192.168.70.91."
  type        = string
  default     = "00:50:56:3F:00:66"
}
variable "mac_kafka_schema_registry_2_primary" {
  description = "schema-registry-2 primary NIC (VMnet11). Pinned to 192.168.70.92."
  type        = string
  default     = "00:50:56:3F:00:67"
}
variable "mac_kafka_connect_1_primary" {
  description = "kafka-connect-1 primary NIC (VMnet11). Pinned to 192.168.70.95."
  type        = string
  default     = "00:50:56:3F:00:68"
}
variable "mac_kafka_connect_2_primary" {
  description = "kafka-connect-2 primary NIC (VMnet11). Pinned to 192.168.70.96."
  type        = string
  default     = "00:50:56:3F:00:69"
}
variable "mac_kafka_ksqldb_1_primary" {
  description = "ksqldb-1 primary NIC (VMnet11). Pinned to 192.168.70.97."
  type        = string
  default     = "00:50:56:3F:00:6A"
}
variable "mac_kafka_ksqldb_2_primary" {
  description = "ksqldb-2 primary NIC (VMnet11). Pinned to 192.168.70.98."
  type        = string
  default     = "00:50:56:3F:00:6B"
}
variable "mac_kafka_mm2_1_primary" {
  description = "mm2-1 primary NIC (VMnet11). Pinned to 192.168.70.85."
  type        = string
  default     = "00:50:56:3F:00:6C"
}
variable "mac_kafka_mm2_2_primary" {
  description = "mm2-2 primary NIC (VMnet11). Pinned to 192.168.70.86."
  type        = string
  default     = "00:50:56:3F:00:6D"
}
variable "mac_kafka_rest_1_primary" {
  description = "kafka-rest-1 primary NIC (VMnet11). Pinned to 192.168.70.88."
  type        = string
  default     = "00:50:56:3F:00:6E"
}

# ─── Phase 0.G.1 — OLTP tier: Redis Cluster dnsmasq reservations ──────────
# nexus-infra-oltp clones the 6 Redis VMs but the gateway is foundation's
# responsibility -- the dhcp-host reservations live here so two terraform
# repos never race on /etc/dnsmasq.d/. The 6 mac_oltp_redis_*_primary
# defaults MUST match nexus-infra-oltp/terraform/envs/oltp/variables.tf's
# MAC allocation 1:1 (00:50:56:3F:00:70-75). role-overlay-gateway-oltp-
# reservations.tf consumes these.
#
# Later OLTP-tier sub-phases (0.G.2 Mongo / 0.G.3 Percona / 0.G.4 Patroni /
# 0.G.7 SQL FCI/AG) add their own MAC variables + reservations here as they
# ship. MAC pool reserved for 0.G OLTP per the 0.G.0 audit allocation:
# :70-:88 (25 contiguous MACs for the 25 OLTP-tier VMs).

variable "enable_oltp_dhcp_reservations" {
  description = "Toggle: write dnsmasq dhcp-host reservations on nexus-gateway for the OLTP tier (Phase 0.G). Currently 6 Redis reservations (0.G.1); later sub-phases extend this overlay with Mongo / Percona / Patroni / SQL FCI/AG reservations. Default true (steady state once Phase 0.G starts). Same partial-apply-destruction landmine class as enable_kafka_dhcp_reservations -- a foundation apply WITHOUT this var on a lab that had it enabled would silently destroy the reservations + the redis clones would lose their canonical IPs on next DHCP renew. Opt out with -Vars enable_oltp_dhcp_reservations=false ONLY on a pre-Phase-0.G lab."
  type        = bool
  default     = true
}

variable "mac_oltp_redis_1_primary" {
  description = "redis-1 primary NIC (VMnet11). Pinned to 192.168.70.81 (shard 1 primary)."
  type        = string
  default     = "00:50:56:3F:00:70"
}
variable "mac_oltp_redis_2_primary" {
  description = "redis-2 primary NIC (VMnet11). Pinned to 192.168.70.82 (shard 1 replica)."
  type        = string
  default     = "00:50:56:3F:00:71"
}
variable "mac_oltp_redis_3_primary" {
  description = "redis-3 primary NIC (VMnet11). Pinned to 192.168.70.83 (shard 2 primary)."
  type        = string
  default     = "00:50:56:3F:00:72"
}
variable "mac_oltp_redis_4_primary" {
  description = "redis-4 primary NIC (VMnet11). Pinned to 192.168.70.84 (shard 2 replica)."
  type        = string
  default     = "00:50:56:3F:00:73"
}
variable "mac_oltp_redis_5_primary" {
  description = "redis-5 primary NIC (VMnet11). Pinned to 192.168.70.87 (shard 3 primary). Note: .85/.86 are mm2 (kafka), .88 is kafka-rest, so redis-5 jumps to .87 per vms.yaml."
  type        = string
  default     = "00:50:56:3F:00:74"
}
variable "mac_oltp_redis_6_primary" {
  description = "redis-6 primary NIC (VMnet11). Pinned to 192.168.70.89 (shard 3 replica). Note: .88 is kafka-rest, so redis-6 jumps to .89 per vms.yaml."
  type        = string
  default     = "00:50:56:3F:00:75"
}

# ─── Phase 0.G.2 -- MongoDB Replica Set MACs (3 nodes) ────────────────────
# Next 3 in the 0.G OLTP pool after redis (:70-:75). Pinned to .71/.72/.73
# on VMnet11 per nexus-platform-plan/docs/infra/vms.yaml (cluster: mongo).
variable "mac_oltp_mongo_1_primary" {
  description = "mongo-1 primary NIC (VMnet11). Pinned to 192.168.70.71 (initial PRIMARY for rs.initiate; replica set elects after that)."
  type        = string
  default     = "00:50:56:3F:00:76"
}
variable "mac_oltp_mongo_2_primary" {
  description = "mongo-2 primary NIC (VMnet11). Pinned to 192.168.70.72 (replica set member 1)."
  type        = string
  default     = "00:50:56:3F:00:77"
}
variable "mac_oltp_mongo_3_primary" {
  description = "mongo-3 primary NIC (VMnet11). Pinned to 192.168.70.73 (replica set member 2)."
  type        = string
  default     = "00:50:56:3F:00:78"
}

# Phase 0.G.3: 5 MACs for the Percona XtraDB Cluster + ProxySQL pair, pinned
# to .51-.55 on VMnet11 per nexus-platform-plan/docs/infra/vms.yaml (cluster:
# percona). pxc-node-1/2/3 are the Galera-replicated data plane; proxysql-1/2
# sit in front as the connection pooler + LB, with a VRRP-floated VIP at .50
# (configured per-node by the oltp env, NOT a dhcp reservation).
variable "mac_oltp_pxc_1_primary" {
  description = "pxc-node-1 primary NIC (VMnet11). Pinned to 192.168.70.51 (Galera node, candidate bootstrap node)."
  type        = string
  default     = "00:50:56:3F:00:79"
}
variable "mac_oltp_pxc_2_primary" {
  description = "pxc-node-2 primary NIC (VMnet11). Pinned to 192.168.70.52 (Galera node)."
  type        = string
  default     = "00:50:56:3F:00:7A"
}
variable "mac_oltp_pxc_3_primary" {
  description = "pxc-node-3 primary NIC (VMnet11). Pinned to 192.168.70.53 (Galera node)."
  type        = string
  default     = "00:50:56:3F:00:7B"
}
variable "mac_oltp_proxysql_1_primary" {
  description = "proxysql-1 primary NIC (VMnet11). Pinned to 192.168.70.54 (ProxySQL instance 1; keepalived MASTER candidate for VIP .50)."
  type        = string
  default     = "00:50:56:3F:00:7C"
}
variable "mac_oltp_proxysql_2_primary" {
  description = "proxysql-2 primary NIC (VMnet11). Pinned to 192.168.70.55 (ProxySQL instance 2; keepalived BACKUP for VIP .50)."
  type        = string
  default     = "00:50:56:3F:00:7D"
}

# Phase 0.G.4: 8 MACs for the Patroni PostgreSQL HA stack (3 patroni + 3 etcd
# + 2 haproxy), pinned to .61-.68 on VMnet11 per nexus-platform-plan/docs/infra/
# vms.yaml (cluster: postgres). The 3 patroni nodes form a streaming-replication
# cluster with Patroni 4 orchestration (etcd DCS for leader election). The 3
# etcd nodes form a 3-member raft quorum dedicated to Patroni's DCS (NOT the
# foundation vault-transit cluster). The 2 haproxy nodes form an HA pair with
# a keepalived-floated VIP at 192.168.70.60 (priority 110 MASTER + 100 BACKUP,
# unicast mode -- mirrors the 0.G.3 proxysql-1/2 pattern). The VIP is NOT a
# dhcp reservation -- it floats between haproxy-pg-1/-2 via VRRP, configured
# per-node by the oltp env (which owns the per-node haproxy + keepalived config).
variable "mac_oltp_pg_primary_primary" {
  description = "pg-primary primary NIC (VMnet11). Pinned to 192.168.70.61 (Patroni candidate leader at first apply; cluster elects after that)."
  type        = string
  default     = "00:50:56:3F:00:7E"
}
variable "mac_oltp_pg_replica_1_primary" {
  description = "pg-replica-1 primary NIC (VMnet11). Pinned to 192.168.70.62 (Patroni replica)."
  type        = string
  default     = "00:50:56:3F:00:7F"
}
variable "mac_oltp_pg_replica_2_primary" {
  description = "pg-replica-2 primary NIC (VMnet11). Pinned to 192.168.70.63 (Patroni replica)."
  type        = string
  default     = "00:50:56:3F:00:80"
}
variable "mac_oltp_etcd_1_primary" {
  description = "etcd-1 primary NIC (VMnet11). Pinned to 192.168.70.64 (etcd member for Patroni DCS)."
  type        = string
  default     = "00:50:56:3F:00:81"
}
variable "mac_oltp_etcd_2_primary" {
  description = "etcd-2 primary NIC (VMnet11). Pinned to 192.168.70.65 (etcd member for Patroni DCS)."
  type        = string
  default     = "00:50:56:3F:00:82"
}
variable "mac_oltp_etcd_3_primary" {
  description = "etcd-3 primary NIC (VMnet11). Pinned to 192.168.70.66 (etcd member for Patroni DCS)."
  type        = string
  default     = "00:50:56:3F:00:83"
}
variable "mac_oltp_haproxy_pg_1_primary" {
  description = "haproxy-pg-1 primary NIC (VMnet11). Pinned to 192.168.70.67 (HAProxy LB; keepalived MASTER candidate for VIP .60)."
  type        = string
  default     = "00:50:56:3F:00:84"
}
variable "mac_oltp_haproxy_pg_2_primary" {
  description = "haproxy-pg-2 primary NIC (VMnet11). Pinned to 192.168.70.68 (HAProxy LB; keepalived BACKUP for VIP .60)."
  type        = string
  default     = "00:50:56:3F:00:85"
}

# Phase 0.G.7: 4 MACs for the SQL Server FCI + AG cluster (2 FCI nodes
# sharing an iSCSI LUN + 2 async AG replicas), pinned to .11-.14 on VMnet11
# per nexus-platform-plan/docs/infra/vms.yaml (cluster: sqlserver). All 4
# nodes are WSFC members forming a single 4-node node-majority cluster;
# sql-fci-1/2 own the FCI virtual server (VIP .16) sharing iSCSI data on
# the LUN from nexus-gateway; sql-ag-rep-1/2 hold async AG replicas of the
# AG'd user databases. The WSFC cluster IP .15, FCI virtual server .16, and
# AG Listener .17 are NOT dhcp reservations -- they are floating VIPs owned
# by WSFC and migrate with cluster role failover. Per ADR-0025, the AG
# Listener (.17) is the LB-tier HA primitive (WSFC-managed; client connection
# strings target the Listener IP). The Listener's TLS cert has .17 in its
# IP-SAN so `Encrypt=True;TrustServerCertificate=False` validates against
# the floating VIP across failover.
variable "mac_oltp_sql_fci_1_primary" {
  description = "sql-fci-1 primary NIC (VMnet11). Pinned to 192.168.70.11 (FCI node 1; WSFC member; iSCSI initiator)."
  type        = string
  default     = "00:50:56:3F:00:86"
}
variable "mac_oltp_sql_fci_2_primary" {
  description = "sql-fci-2 primary NIC (VMnet11). Pinned to 192.168.70.12 (FCI node 2; WSFC member; iSCSI initiator)."
  type        = string
  default     = "00:50:56:3F:00:87"
}
variable "mac_oltp_sql_ag_rep_1_primary" {
  description = "sql-ag-rep-1 primary NIC (VMnet11). Pinned to 192.168.70.13 (AG async replica 1; WSFC member; no iSCSI -- local storage only)."
  type        = string
  default     = "00:50:56:3F:00:88"
}
variable "mac_oltp_sql_ag_rep_2_primary" {
  description = "sql-ag-rep-2 primary NIC (VMnet11). Pinned to 192.168.70.14 (AG async replica 2; WSFC member; no iSCSI -- local storage only)."
  type        = string
  default     = "00:50:56:3F:00:89"
}

# ─── Phase 0.G.7 -- iSCSI target on nexus-gateway for FCI shared storage ─
# Per ADR-0026 (SQL FCI iSCSI shared storage on nexus-gateway). The FCI
# pair (sql-fci-1/-2) requires a shared block device for the SQL Server
# data + log directories. VMware Workstation Pro has no shared-disk
# primitive (no multi-writer flag, no shared-SCSI bus support in the UI;
# only ESXi has these). The smallest tractable shim is an iSCSI target
# running on nexus-gateway (.70.1) exporting a single LUN to both FCI
# nodes via VMnet11. CHAP authentication; per-IP ACL restricting the
# target to .70.11/.12 only. The LUN is a sparse-file backing on the
# gateway's local disk (60 GB default -- room for SQL system DBs + a
# few user DBs).
variable "enable_iscsi_target_sqlfci" {
  description = "Toggle: install tgt + write the iSCSI target export for the SQL FCI shared LUN on nexus-gateway (Phase 0.G.7). Default true (steady state once Phase 0.G.7 starts). Same partial-apply-destruction landmine class as the kafka/oltp reservations -- a foundation apply WITHOUT this var on a lab that had it enabled would silently destroy the iSCSI export + the FCI pair would lose access to their shared cluster disk on next reboot. Opt out with -Vars enable_iscsi_target_sqlfci=false ONLY on a pre-0.G.7 lab."
  type        = bool
  default     = true
}
variable "iscsi_sqlfci_lun_size_gb" {
  description = "Size (GB) of the iSCSI LUN backing file at /srv/iscsi/sql-fci-shared.img on nexus-gateway. 60 GB is enough for SQL system DBs + ~30 GB user DBs at lab scale. Sparse-allocated (uses ~0 disk until written)."
  type        = number
  default     = 60
}
variable "iscsi_sqlfci_target_iqn" {
  description = "iSCSI Qualified Name for the SQL FCI shared LUN. Convention: iqn.<YYYY-MM>.<reverse-dns>:<service>.<lun>. 2026-05 was when 0.G.7 landed; reverse-dns is local.nexus (lab-internal)."
  type        = string
  default     = "iqn.2026-05.local.nexus:sql-fci.lun1"
}
variable "iscsi_sqlfci_chap_username" {
  description = "CHAP username for the SQL FCI iSCSI target. CHAP secret is sticky-seeded in Vault KV at nexus/oltp/sqlserver/iscsi-chap-secret by the security env."
  type        = string
  default     = "sql-fci-initiator"
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

# ─── Phase 0.D.5.4 — Vault Agent on member servers ───────────────────────
#
# Installs the Vault Agent service on dc-nexus + nexus-jumpbox, configured
# with each host's narrow AppRole (defined in security env). Each Agent
# renders one cred from KV to a file on disk as proof-of-concept. Real
# consumers (SQL Server config files, IIS app config, scheduled tasks)
# come when those workloads deploy in 0.G+.
#
# Cross-env coupling: reads the security env's AppRole creds JSON sidecars
# from $HOME/.nexus/vault-agent-{dc-nexus,nexus-jumpbox}.json. Best-effort:
# WARN+skip if the JSON is absent (security env not yet applied).
#
# Vault Agent binary download: from releases.hashicorp.com via nexus-gateway
# Internet egress. Each host downloads its own copy on first apply.

variable "enable_vault_agent_install" {
  description = "Master toggle: install Vault Agent on dc-nexus + nexus-jumpbox. Default true."
  type        = bool
  default     = true
}

variable "enable_dc_vault_agent" {
  description = "Toggle: install Vault Agent on dc-nexus. Default true. Renders nexus/foundation/dc-nexus/dsrm to C:\\ProgramData\\nexus\\agent\\dsrm.txt as a proof-of-concept."
  type        = bool
  default     = true
}

variable "enable_jumpbox_vault_agent" {
  description = "Toggle: install Vault Agent on nexus-jumpbox. Default true. Renders nexus/foundation/identity/nexusadmin to C:\\ProgramData\\nexus\\agent\\nexusadmin-pwd.txt as a proof-of-concept."
  type        = bool
  default     = true
}

variable "vault_agent_version" {
  description = "Vault binary version to install on each member server. Should match the Vault cluster's version (default 1.18.4 per packer/vault/variables.pkr.hcl)."
  type        = string
  default     = "1.18.4"
}

variable "vault_agent_dc_nexus_creds_file" {
  description = "Build-host path where the security env wrote dc-nexus's Vault Agent role-id+secret-id JSON sidecar. Mirrors security env default."
  type        = string
  default     = "~/.nexus/vault-agent-dc-nexus.json"
}

variable "vault_agent_nexus_jumpbox_creds_file" {
  description = "Build-host path where the security env wrote nexus-jumpbox's Vault Agent role-id+secret-id JSON sidecar. Mirrors security env default."
  type        = string
  default     = "~/.nexus/vault-agent-nexus-jumpbox.json"
}

# ─── Phase 0.E.4a — NFS server on gateway for Portainer CE shared /data ───
variable "enable_gateway_nfs_portainer" {
  description = "Phase 0.E.4a toggle: install nfs-kernel-server on nexus-gateway + export /srv/nfs/portainer-data NFSv4-only to the 3 swarm managers. Patches /etc/nftables.conf in-place to allow inbound tcp/2049 from manager IPs (managed via marker comment for idempotent re-applies). Portainer CE has no native HA but Swarm reschedules the single Server replica on manager failure -- shared /data lets the new replica pick up state. Default true (steady state per memory/feedback_terraform_partial_apply_destroys_resources.md). Set false to skip the NFS path (requires alternative shared-storage strategy or accept state loss on replica reschedule)."
  type        = bool
  default     = true
}

variable "portainer_nfs_export_path" {
  description = "Path on nexus-gateway exported via NFSv4 for Portainer's /data. Default /srv/nfs/portainer-data."
  type        = string
  default     = "/srv/nfs/portainer-data"
}

variable "portainer_nfs_allowed_clients" {
  description = "Comma-separated list of client IPs permitted to mount the Portainer NFS export. Defaults to the 3 swarm-manager VMnet11 IPs (.111-.113) -- workers don't run Portainer Server so they don't need access."
  type        = string
  default     = "192.168.70.111,192.168.70.112,192.168.70.113"
}

# ─── Phase 0.E.4c — dnsmasq A-record portainer.nexus.lab ──────────────────
variable "enable_gateway_portainer_dns" {
  description = "Phase 0.E.4c toggle: register a multi-A host-record for portainer.nexus.lab on nexus-gateway's dnsmasq, mapping to the 3 swarm-manager VMnet11 IPs. Combined with Docker Swarm's routing mesh, this gives a single canonical URL `https://portainer.nexus.lab:9443` that works regardless of which manager has the active Portainer Server replica scheduled. Default true."
  type        = bool
  default     = true
}

variable "portainer_dns_name" {
  description = "DNS hostname registered on nexus-gateway dnsmasq for the Portainer CE Server. Default `portainer.nexus.lab`. The TLS cert (issued by security env's portainer-server PKI role) MUST cover this CN."
  type        = string
  default     = "portainer.nexus.lab"
}

variable "portainer_dns_manager_ips" {
  description = "List of swarm-manager VMnet11 IPs registered as A-records for the Portainer DNS name. Defaults to .111-.113 (3-manager round-robin)."
  type        = list(string)
  default     = ["192.168.70.111", "192.168.70.112", "192.168.70.113"]
}

# ─── Phase 0.G.5/0.G.6 — Analytics tier (ClickHouse + StarRocks) ──────────
# dhcp-host reservations (MAC block :8A-:98 after the OLTP tier's :89) +
# round-robin DNS front doors + the NFS backup repository (ADR-0032).

variable "enable_analytics_dhcp_reservations" {
  description = "Toggle: write the analytics-tier dhcp-host reservations on nexus-gateway dnsmasq (ClickHouse :8A-:92 -> .41-.49 at 0.G.5; StarRocks :93-:98 -> .31-.36 at 0.G.6). Default true."
  type        = bool
  default     = true
}

# ClickHouse node primary MACs (VMnet11). MUST match nexus-infra-analytics
# envs/analytics-clickhouse mac_ch_*_primary defaults. Block :8A-:92.
variable "mac_analytics_ch_keeper_1_primary" {
  type    = string
  default = "00:50:56:3F:00:8A"
}
variable "mac_analytics_ch_keeper_2_primary" {
  type    = string
  default = "00:50:56:3F:00:8B"
}
variable "mac_analytics_ch_keeper_3_primary" {
  type    = string
  default = "00:50:56:3F:00:8C"
}
variable "mac_analytics_ch_shard1_rep1_primary" {
  type    = string
  default = "00:50:56:3F:00:8D"
}
variable "mac_analytics_ch_shard1_rep2_primary" {
  type    = string
  default = "00:50:56:3F:00:8E"
}
variable "mac_analytics_ch_shard2_rep1_primary" {
  type    = string
  default = "00:50:56:3F:00:8F"
}
variable "mac_analytics_ch_shard2_rep2_primary" {
  type    = string
  default = "00:50:56:3F:00:90"
}
variable "mac_analytics_ch_shard3_rep1_primary" {
  type    = string
  default = "00:50:56:3F:00:91"
}
variable "mac_analytics_ch_shard3_rep2_primary" {
  type    = string
  default = "00:50:56:3F:00:92"
}

# Round-robin DNS front doors (ADR-0031 -- no VIP).
variable "enable_gateway_analytics_dns" {
  description = "Toggle: write the analytics round-robin host-records on nexus-gateway dnsmasq (clickhouse.nexus.lab -> 6 data nodes; starrocks-fe.nexus.lab -> 3 FE when those IPs are provided). Default true."
  type        = bool
  default     = true
}
variable "analytics_clickhouse_dns_name" {
  description = "Round-robin DNS name for the ClickHouse cluster front door. The clickhouse-server PKI leaf certs carry this in their SANs so verify-full validates whichever data node answers (ADR-0031)."
  type        = string
  default     = "clickhouse.nexus.lab"
}
variable "analytics_clickhouse_data_ips" {
  description = "ClickHouse data-node VMnet11 IPs registered as A-records for the round-robin name (the 6 shard-replica nodes)."
  type        = list(string)
  default     = ["192.168.70.44", "192.168.70.45", "192.168.70.46", "192.168.70.47", "192.168.70.48", "192.168.70.49"]
}
variable "analytics_starrocks_dns_name" {
  description = "Round-robin DNS name for the StarRocks FE front door (MySQL :9030 / HTTP :8030)."
  type        = string
  default     = "starrocks-fe.nexus.lab"
}
variable "analytics_starrocks_fe_ips" {
  description = "StarRocks FE VMnet11 IPs for the round-robin name (the 3 FE). Set at 0.G.6 so the starrocks-fe.nexus.lab record is written; leave empty before 0.G.6 to write only the ClickHouse record."
  type        = list(string)
  default     = ["192.168.70.31", "192.168.70.32", "192.168.70.33"]
}

# NFS backup repository (ADR-0032). MinIO/S3 migration deferred to 0.L.
variable "enable_gateway_nfs_analytics" {
  description = "Toggle: stand up the /srv/nfs/analytics-backups NFS export on nexus-gateway for ClickHouse/StarRocks BACKUP/RESTORE (ADR-0032). Default true."
  type        = bool
  default     = true
}
variable "analytics_nfs_export_path" {
  description = "NFS export directory on nexus-gateway for the analytics backup repository. fsid=1 (portainer holds fsid=0). Default /srv/nfs/analytics-backups."
  type        = string
  default     = "/srv/nfs/analytics-backups"
}
variable "analytics_nfs_allowed_clients" {
  description = "CSV of VMnet11 IPs allowed to mount the analytics backup export. The 6 ClickHouse data nodes (.44-.49) + the StarRocks FE/BE that drive BACKUP SNAPSHOT (.31-.36)."
  type        = string
  default     = "192.168.70.44,192.168.70.45,192.168.70.46,192.168.70.47,192.168.70.48,192.168.70.49,192.168.70.31,192.168.70.32,192.168.70.33,192.168.70.34,192.168.70.35,192.168.70.36"
}

# StarRocks node primary MACs (VMnet11). MUST match nexus-infra-analytics
# envs/analytics-starrocks mac_sr_*_primary defaults. Block :93-:98.
variable "mac_analytics_sr_fe_leader_primary" {
  type    = string
  default = "00:50:56:3F:00:93"
}
variable "mac_analytics_sr_fe_follower_1_primary" {
  type    = string
  default = "00:50:56:3F:00:94"
}
variable "mac_analytics_sr_fe_follower_2_primary" {
  type    = string
  default = "00:50:56:3F:00:95"
}
variable "mac_analytics_sr_be_1_primary" {
  type    = string
  default = "00:50:56:3F:00:96"
}
variable "mac_analytics_sr_be_2_primary" {
  type    = string
  default = "00:50:56:3F:00:97"
}
variable "mac_analytics_sr_be_3_primary" {
  type    = string
  default = "00:50:56:3F:00:98"
}

# ─── Phase 0.L.5 -- StarRocks shared-data tier (ADR-0037) ─────────────────
# Second StarRocks cluster (3 FE + 2 CN, run_mode=shared_data) running parallel
# to the sealed shared-nothing one. Internal tables in a MinIO storage volume.
# MAC block :A5-:A9 (the reserved gap between 0.L.3 Spark/ZK :AA-:AE and the
# 0.L.4 registry :AF-:B1). MUST match nexus-infra-analytics envs/analytics-
# starrocks-sd mac_sr_sd_*_primary defaults. CN-2 at .40 is a documented
# decade-spill: SR decade .3x only had 4 free slots (.30/.37/.38/.39); the
# full-HA 3FE+2CN topology needs 5, so CN-2 spills to .40 (first free
# ClickHouse-decade slot) per ADR-0037.
variable "mac_analytics_sr_sd_fe_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A5"
}
variable "mac_analytics_sr_sd_fe_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A6"
}
variable "mac_analytics_sr_sd_fe_3_primary" {
  type    = string
  default = "00:50:56:3F:00:A7"
}
variable "mac_analytics_sr_sd_cn_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A8"
}
variable "mac_analytics_sr_sd_cn_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A9"
}

variable "analytics_starrocks_sd_dns_name" {
  description = "Round-robin DNS name for the StarRocks shared-data FE front door (MySQL :9030 / HTTP :8030). Separate from the sealed starrocks-fe.nexus.lab (shared-nothing) -- both clusters run in parallel."
  type        = string
  default     = "starrocks-sd-fe.nexus.lab"
}
variable "analytics_starrocks_sd_fe_ips" {
  description = "StarRocks shared-data FE VMnet11 IPs for the round-robin name (the 3 sd FE at .37/.38/.39). Leave empty before 0.L.5 to skip writing this record."
  type        = list(string)
  default     = ["192.168.70.37", "192.168.70.38", "192.168.70.39"]
}

# ─── Phase 0.L -- Lakehouse tier (08-spark): MinIO + Spark + Iceberg ───────
# dhcp-host reservations + round-robin DNS for the 16 lakehouse nodes. MAC block
# :99-:A3 (contiguous after the analytics tier, :98) for 0.L.1/0.L.2; the 0.L.3
# Spark HA expansion uses :AA-:AE (the :A4-:A9 gap is reserved for 0.L.4 registry
# + 0.L.5 StarRocks shared-data). MUST match nexus-infra-lakehouse envs/lakehouse-*/.
variable "enable_lakehouse_dhcp_reservations" {
  description = "Toggle: write the 16 lakehouse dhcp-host reservations on nexus-gateway dnsmasq (MinIO .141-.144 + Spark masters .140/.153 + Spark workers .145/.146/.154 + ZooKeeper .155-.157 + Iceberg REST .147/.148 + Iceberg PG .149/.150). Default true."
  type        = bool
  default     = true
}
variable "mac_lakehouse_spark_master_primary" {
  type    = string
  default = "00:50:56:3F:00:99"
}
variable "mac_lakehouse_minio_1_primary" {
  type    = string
  default = "00:50:56:3F:00:9A"
}
variable "mac_lakehouse_minio_2_primary" {
  type    = string
  default = "00:50:56:3F:00:9B"
}
variable "mac_lakehouse_minio_3_primary" {
  type    = string
  default = "00:50:56:3F:00:9C"
}
variable "mac_lakehouse_minio_4_primary" {
  type    = string
  default = "00:50:56:3F:00:9D"
}
variable "mac_lakehouse_spark_worker_1_primary" {
  type    = string
  default = "00:50:56:3F:00:9E"
}
variable "mac_lakehouse_spark_worker_2_primary" {
  type    = string
  default = "00:50:56:3F:00:9F"
}
variable "mac_lakehouse_iceberg_rest_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A0"
}
variable "mac_lakehouse_iceberg_rest_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A1"
}
variable "mac_lakehouse_iceberg_pg_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A2"
}
variable "mac_lakehouse_iceberg_pg_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A3"
}
# 0.L.3 Spark HA expansion. NOTE the MAC gap: :A4 is reserved for 0.L.4 registry
# (registry-1) and :A5-:A9 for 0.L.5 StarRocks shared-data (sr-sd-fe-1..3 +
# sr-sd-cn-1/2), so the 0.L.3 Spark/ZooKeeper nodes start at :AA.
variable "mac_lakehouse_spark_master_2_primary" {
  type    = string
  default = "00:50:56:3F:00:AA"
}
variable "mac_lakehouse_spark_worker_3_primary" {
  type    = string
  default = "00:50:56:3F:00:AB"
}
variable "mac_lakehouse_zookeeper_1_primary" {
  type    = string
  default = "00:50:56:3F:00:AC"
}
variable "mac_lakehouse_zookeeper_2_primary" {
  type    = string
  default = "00:50:56:3F:00:AD"
}
variable "mac_lakehouse_zookeeper_3_primary" {
  type    = string
  default = "00:50:56:3F:00:AE"
}

# Round-robin DNS front doors (ADR-0031/0033 -- no VIP). Only names with a
# non-empty IP list are written; iceberg/spark IPs populate at 0.L.2/0.L.3.
variable "enable_gateway_lakehouse_dns" {
  description = "Toggle: write the lakehouse round-robin records on nexus-gateway dnsmasq (minio.nexus.lab -> 4 MinIO; iceberg.nexus.lab -> 2 REST; spark-master.nexus.lab). Default true."
  type        = bool
  default     = true
}
variable "lakehouse_minio_dns_name" {
  description = "Round-robin DNS name for the MinIO S3 endpoint. The minio-server PKI leaf certs carry this in their SANs so verify-full validates whichever node answers (ADR-0033)."
  type        = string
  default     = "minio.nexus.lab"
}
variable "lakehouse_minio_ips" {
  description = "MinIO node VMnet11 IPs registered as A-records for the round-robin name (the 4 nodes)."
  type        = list(string)
  default     = ["192.168.70.141", "192.168.70.142", "192.168.70.143", "192.168.70.144"]
}
variable "lakehouse_iceberg_dns_name" {
  description = "Round-robin DNS name for the Iceberg REST catalog front door (2 HA instances)."
  type        = string
  default     = "iceberg.nexus.lab"
}
variable "lakehouse_iceberg_ips" {
  description = "Iceberg REST VMnet11 IPs for the round-robin name (the 2 Nessie instances). Set at 0.L.2."
  type        = list(string)
  default     = ["192.168.70.147", "192.168.70.148"]
}
variable "lakehouse_iceberg_db_dns_name" {
  description = "DNS name for the Iceberg catalog PG front door (the keepalived VRRP VIP). Single A-record -> the VIP."
  type        = string
  default     = "iceberg-db.nexus.lab"
}
variable "lakehouse_iceberg_db_vip" {
  description = "Iceberg catalog PG keepalived VRRP VIP (.151). Set at 0.L.2; empty before then."
  type        = list(string)
  default     = ["192.168.70.151"]
}
variable "lakehouse_spark_master_dns_name" {
  description = "Round-robin DNS name for the Spark master Web UI front door (the 2 HA masters). The multi-master cluster URL itself uses node IPs, not this name."
  type        = string
  default     = "spark-master.nexus.lab"
}
variable "lakehouse_spark_master_ips" {
  description = "Spark master VMnet11 IPs for the round-robin name (.140 + .153, HA pair). Set at 0.L.3."
  type        = list(string)
  default     = ["192.168.70.140", "192.168.70.153"]
}

# ─── Phase 0.L.4 -- registry tier (09-platform; Harbor HA, ADR-0036) ──────
# 4 dhcp-host reservations (registry-1/2 + registry-pg-1/2) + round-robin DNS
# registry.nexus.lab (app HA) + the registry-db.nexus.lab VIP A-record. MACs:
# registry-1 reuses :A4; registry-2/pg-1/pg-2 use :AF/:B0/:B1.
variable "enable_registry_dhcp_reservations" {
  description = "Toggle: write the 4 registry-tier dhcp-host reservations on nexus-gateway dnsmasq. Default true."
  type        = bool
  default     = true
}
variable "mac_registry_1_primary" {
  description = "registry-1 (Harbor app) primary NIC MAC -> 192.168.70.115. Reuses the canon :A4 reservation."
  type        = string
  default     = "00:50:56:3F:00:A4"
}
variable "mac_registry_2_primary" {
  description = "registry-2 (Harbor app) primary NIC MAC -> 192.168.70.116."
  type        = string
  default     = "00:50:56:3F:00:AF"
}
variable "mac_registry_pg_1_primary" {
  description = "registry-pg-1 (PG/Redis primary) primary NIC MAC -> 192.168.70.117."
  type        = string
  default     = "00:50:56:3F:00:B0"
}
variable "mac_registry_pg_2_primary" {
  description = "registry-pg-2 (PG/Redis replica) primary NIC MAC -> 192.168.70.118."
  type        = string
  default     = "00:50:56:3F:00:B1"
}
variable "enable_gateway_registry_dns" {
  description = "Toggle: write the registry round-robin records on nexus-gateway dnsmasq (registry.nexus.lab -> 2 Harbor app; registry-db.nexus.lab -> the VRRP VIP). Default true."
  type        = bool
  default     = true
}
variable "registry_dns_name" {
  description = "Round-robin DNS name for the Harbor front door (2 stateless app nodes). The registry-server PKI leaf certs carry this in their SANs (ADR-0031/0036)."
  type        = string
  default     = "registry.nexus.lab"
}
variable "registry_app_ips" {
  description = "Harbor app node VMnet11 IPs registered as A-records for the round-robin name (.115 + .116)."
  type        = list(string)
  default     = ["192.168.70.115", "192.168.70.116"]
}
variable "registry_db_dns_name" {
  description = "DNS name for the registry datastore front door (the keepalived VRRP VIP). Single A-record -> the VIP."
  type        = string
  default     = "registry-db.nexus.lab"
}
variable "registry_db_vip" {
  description = "Registry datastore keepalived VRRP VIP (.119; PG primary + Redis master follow it)."
  type        = string
  default     = "192.168.70.119"
}
