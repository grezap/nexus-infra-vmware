# nexus-infra-vmware

[![Packer](https://img.shields.io/badge/Packer-1.11+-blue)](https://www.packer.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.9+-purple)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Blueprint](https://img.shields.io/badge/blueprint-nexus--platform--plan%20v0.1.2-orange)](https://github.com/grezap/nexus-platform-plan)

Infrastructure-as-code for the **NexusPlatform 66-VM lab** running on **VMware Workstation Pro** (host `10.0.70.101`). Produces golden VM templates with Packer, provisions the fleet with Terraform, configures guest OS with Ansible.

> **Canon:** This repo implements [Phase 0.B–0.C](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) of the NexusPlatform blueprint. Read [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan) first.

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
  deb13/                     Generic Debian 13 template (stub, Phase 0.B.2)
  ubuntu24/                  Ubuntu 24.04 template    (stub, Phase 0.B.3)
  ws2025-core/               Windows Server 2025 Core (stub, Phase 0.B.4)
  ws2025-desktop/            Windows Server 2025 Desktop (stub, Phase 0.B.5)
  win11ent/                  Windows 11 Enterprise    (stub, Phase 0.B.6)

terraform/
  gateway/                   nexus-gateway VM instantiation
  modules/vm/                Reusable VM module (used by higher-level envs later)

docs/
  architecture.md            Design decisions + diagrams
  nexus-gateway.md           Gateway deep-dive + runbook (per-VM)
  handbook.md                Operator handbook (cross-cutting command reference)
  licensing.md               Windows licensing canon

scripts/                     Host helpers (invoked from Makefile)

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

This repo tags `v0.X.Y` aligned with implementation milestones. `v0.1.0` = scaffold + `nexus-gateway` build path. See [`CHANGELOG.md`](./CHANGELOG.md).

## License

MIT — see [`LICENSE`](./LICENSE).
