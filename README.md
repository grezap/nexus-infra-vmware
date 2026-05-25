# nexus-infra-vmware

[![Packer](https://img.shields.io/badge/Packer-1.11+-blue)](https://www.packer.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.9+-purple)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Blueprint](https://img.shields.io/badge/blueprint-nexus--platform--plan%20v0.1.3-orange)](https://github.com/grezap/nexus-platform-plan)
[![Phase](https://img.shields.io/badge/phase-0.D%20closed%20%E2%80%A2%20cross--tier%20IaC%20through%200.L.4-brightgreen)](./CHANGELOG.md)

Infrastructure-as-code for the **NexusPlatform lab** (88 VMs built/cold-rebuild-proven through Phase 0.L.4, on host `10.0.70.101`) running on **VMware Workstation Pro**. Produces golden VM templates with Packer, provisions the fleet with Terraform, configures guest OS with Ansible. Beyond the Tier-1 foundation it owns, this repo hosts the **cross-tier overlays** (gateway DHCP/DNS/VIP records + Vault PKI roles, AppRoles, KV creds, and the Harbor OIDC provider) that every later tier — orchestration, Kafka, OLTP, analytics, lakehouse, registry — consumes.

> **Canon:** This repo implements [Phase 0.B–0.D](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) of the NexusPlatform blueprint. Read [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan) first.
>
> **➜ Want to rebuild a tier from zero?** [`docs/handbook.md` § Quick replay paths](./docs/handbook.md) has the exact short-path: §A foundation tier (gateway + dc-nexus + jumpbox + AD), §B security tier (Vault HA + transit + PKI + LDAPS), §C tear down, §D cold-rebuild canon. Each replay path lists prerequisites + machine-order precedence + selective-ops `-Vars` examples. Cross-tier index: [`nexus-platform-plan/docs/setup-guides.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/setup-guides.md).
>
> **New to Packer / Terraform / Vault / Active Directory / GMSA / LDAPS / AppRole / Transit?** See the [tool stack glossary](https://github.com/grezap/nexus-platform-plan/blob/main/docs/glossary.md) for plain-English definitions.
>
> **Current state (Phase 0.D closed; Phase 0.E `v0.2.0` closed in [`nexus-infra-swarm-nomad`](https://github.com/grezap/nexus-infra-swarm-nomad); Phase 0.H `v0.1.0` closed in [`nexus-infra-kafka`](https://github.com/grezap/nexus-infra-kafka) — this repo carries the cross-cutting Vault + gateway scaffolding both consumer tiers depend on):** Six Packer templates (incl. `vault`) · `foundation` env (DC promotion + AD DS forest + domain-joined jumpbox + AD hardening + Vault-KV-backed bootstrap creds via AppRole + `MinPasswordLength=14` + KV→AD rotation overlay + GMSA scaffolding + Vault Agent on dc-nexus & jumpbox + **NFSv4 export from gateway for Portainer CE shared `/data`** [0.E.4a] + **dnsmasq dhcp-host reservations for the 15-VM Kafka tier** [0.H]) · `security` env (3-node HA Vault on Raft with **transit auto-unseal** via `vault-transit` companion + internal PKI hierarchy with 90-day leaf TTL + LDAPS to AD + `secrets/ldap` AD password rotation + `nexus-foundation-reader` AppRole + `nexus/foundation/*` cred seed + 6 narrow Vault Agent AppRoles for swarm nodes + PKI roles `consul-server` & `nomad-server` & token role **`nomad-cluster`** with `nomad-jobs` policy [0.E.3.3b] + manager Vault Agent policies extended to v4 with `auth/token/create/nomad-cluster` capability + **PKI role `kafka-broker` (server+client EKU, 90-day leaf TTL, 15 kafka-tier hostnames) + 15 narrow Vault Agent AppRoles + per-host JSON sidecars for the whole `03-kafka` tier** [0.H]). All 5 sub-deliverables of 0.D.5 ✅ live; 0.E.3.3b + 0.E.4a Vault/gateway scaffolding ✅ live; 0.H Vault/gateway scaffolding ✅ live (consumed by `nexus-infra-kafka` `v0.1.0`). Chained smoke gates: 0.D smoke (~80 checks) + 0.E.3.3 smoke (~155 checks across `nexus-infra-swarm-nomad`) + 0.H smoke (`0.H.2`-`0.H.5` = 92/37/48/38 across `nexus-infra-kafka`) ALL GREEN.

## What's in here

| Layer | Tool | Purpose |
|---|---|---|
| **Golden images** | Packer 1.11 + `hashicorp/vmware` | Reproducible `.vmx` templates; one per OS |
| **VM provisioning** | Terraform 1.9 + `vmware/vmware-desktop` + `vmrun` fallback | Declaratively create/destroy VMs from templates |
| **Guest config** | Ansible 10 | Role-based post-boot configuration |
| **Validation** | GitHub Actions | `packer validate` + `terraform validate` + `ansible-lint` on every PR |

## The golden images

| Template | OS | Role |
|---|---|---|
| `nexus-gateway` | Debian 13 minimal | **VM #0** — lab edge router (nftables NAT, dnsmasq DHCP+DNS, chrony NTP). Built **FIRST** so every other VM has internet egress |
| `deb13` | Debian 13 | Generic Linux server base (majority of lab) |
| `ubuntu24` | Ubuntu 24.04 LTS | Specific roles needing newer kernels (e.g. MinIO, Spark workers) |
| `ws2025-core` | Windows Server 2025 Core | SQL Server FCI/AG, headless Windows services |
| `ws2025-desktop` | Windows Server 2025 Desktop | Domain controller, RSAT tooling |
| `win11ent` | Windows 11 Enterprise | Windows workstations for nexus-desk testing |

## Quick start — build `nexus-gateway`

```bash
# On the Windows 11 host 10.0.70.101 with VMware Workstation Pro:
make gateway                         # packer build packer/nexus-gateway

# Apply via Terraform (creates .vmx, powers on):
make gateway-apply                   # terraform -chdir=terraform/gateway apply

# Verify:
nexus-cli infrastructure ping-gateway
# Expected: nexus-gateway alive at 192.168.70.1; egress reachable via 1.1.1.1
```

Full walkthrough: [`docs/nexus-gateway.md`](./docs/nexus-gateway.md). Cross-cutting operator commands: [`docs/handbook.md`](./docs/handbook.md).

## Repo layout

```
packer/
  nexus-gateway/             VM #0 — lab edge router (first build)
    nexus-gateway.pkr.hcl
    variables.pkr.hcl
    http/preseed.cfg         Debian automated install
    files/{nftables,dnsmasq,chrony}.conf
    ansible/playbook.yml     post-install config
  deb13/                     Generic Debian 13 template (Phase 0.B.2)
  ubuntu24/                  Ubuntu 24.04 template    (Phase 0.B.3)
  _shared/ansible/roles/     DRY-extracted Linux baseline roles (Phase 0.B.3)
  ws2025-core/               Windows Server 2025 Core (Phase 0.B.4)
  ws2025-desktop/            Windows Server 2025 Desktop Experience (Phase 0.B.5)
  _shared/powershell/        DRY-extracted Windows baseline scripts (Phase 0.B.5)
  win11ent/                  Windows 11 Enterprise    (Phase 0.B.6)
  vault/                     HashiCorp Vault on deb13 (Phase 0.D.1)

terraform/
  gateway/                   nexus-gateway VM instantiation
  modules/vm/                Reusable VM module (used by higher-level envs)
  envs/foundation/           dc-nexus + nexus-jumpbox + AD DS + AD hardening + Vault-KV-backed creds (Phase 0.C.* + 0.D.3 AD-for-Vault + 0.D.4 KV consumer)
  envs/security/             3-node Vault Raft + internal PKI + LDAPS auth + secrets/ldap rotate-role + nexus-foundation-reader AppRole + KV seed (Phase 0.D.1 + 0.D.2 + 0.D.3 + 0.D.4)

docs/
  architecture.md            Design decisions + diagrams
  nexus-gateway.md           Gateway deep-dive + runbook (per-VM)
  handbook.md                Operator handbook (cross-cutting command reference)
  licensing.md               Windows licensing canon

scripts/                     Host helpers (pwsh-native; Makefile is also available)
  foundation.ps1             apply / destroy / smoke for the foundation env
  security.ps1               apply / destroy / smoke for the security (Vault) env
  smoke-0.D.{1,2,3}.ps1      Per-phase chained smoke gates

.github/workflows/
  packer-validate.yml        CI — packer validate + ansible-lint + tf fmt
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| VMware Workstation Pro | 17.5+ | Already installed on host |
| Packer | 1.11+ | `choco install packer` |
| Terraform | 1.9+ | `choco install terraform` |
| Ansible | 10+ | Installed inside a Linux VM or WSL (run from `nexus-gateway` after build) |
| PowerShell | 7+ | `winget install Microsoft.PowerShell` |

## Version

This repo tags `v0.X.Y` aligned with implementation milestones. Tags shipped:

- `v0.1.0` — scaffold + `nexus-gateway` build path (Phase 0.B.1)
- `v0.1.1` — `deb13` + `ubuntu24` baselines + reusable `terraform/modules/vm/` (Phase 0.B.2 + 0.B.3)

Phases 0.B.4 → 0.D.3 have shipped on `main` ahead of formal v-tags; the next tag will batch the full 0.D close-out (cluster + PKI + LDAPS + AD password rotation + KV cred migration). See [`CHANGELOG.md`](./CHANGELOG.md) for the full work log.

## License

MIT — see [`LICENSE`](./LICENSE).
