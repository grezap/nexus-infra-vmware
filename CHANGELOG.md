# Changelog

All notable changes to this repository will be documented in this file.
The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 0.C.1 — `terraform/envs/foundation/`** — first env composing
  multiple `modules/vm/` instances. Lands two `ws2025-desktop` clones on
  VMnet11: `dc-nexus` (MAC `00:50:56:3F:00:25`) and `nexus-admin-jumpbox`
  (MAC `00:50:56:3F:00:26`), both under tier path `H:/VMS/NexusPlatform/10-core/`.
  Shape-template for the remaining 0.C envs (`data`, `ml`, `saas`,
  `microservices`, `demo-minimal`). AD DS promotion + jumpbox tooling
  reservations are downstream role-overlay tickets.
- `Makefile` — `foundation-apply` / `foundation-destroy` targets,
  `init` / `validate` extended to cover `terraform/envs/foundation/`.
- `.github/workflows/packer-validate.yml` — `envs/foundation` added to
  the `terraform` job matrix (fmt + `init -backend=false` + validate).
- `docs/handbook.md` §1c — full reproduce flow for `envs/foundation`,
  MAC allocation table, "why an env not a smoke" rationale.
  §5 directory map + §6 phase table updated to reflect 0.B.5 / 0.B.6 ✅
  and 0.C.1 🔄.

## [0.1.1] — 2026-04-22 — "Windows licensing canon + secret-leak defenses"

Implements the nexus-infra-vmware side of
[nexus-platform-plan v0.1.3](https://github.com/grezap/nexus-platform-plan/releases/tag/v0.1.3)
and [ADR-0144](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md).

### Added

- `docs/licensing.md` — implementation-side licensing doc: `product_source`
  variable contract (`msdn` | `evaluation`), Vault layout at
  `nexus/windows/product-keys/{ws2025-core,ws2025-desktop,win11ent}`,
  pre-Phase-0.D bootstrap via NTFS-ACL'd `%USERPROFILE%\.nexus\secrets\windows-keys.json`,
  5-layer defense-in-depth, operational playbook.
- `.gitleaks.toml` — custom `microsoft-product-key` rule matching the
  5x5 alphanumeric Windows key format, with placeholder/`.tpl`/docs allow-list.
- `scripts/check-no-product-key.ps1` — pwsh pre-commit + CI guard that fails
  on any Microsoft product-key pattern outside allow-listed paths.
- `.github/workflows/packer-validate.yml` — two new jobs: `gitleaks` (full
  history scan on PRs) and `product-key-guard` (pwsh scan of every tracked
  file against the MSFT key regex).
- Per-template `## Licensing — product_source contract` sections in
  `packer/ws2025-core/README.md`, `packer/ws2025-desktop/README.md`,
  `packer/win11ent/README.md` documenting default/`msdn`/`evaluation`
  behaviour, derived `edition`, and Vault paths.

### Changed

- `.gitignore` — hardened for key-bearing artifacts: `**/Autounattend.xml`
  blocked at every path (except `*.tpl`), `*.pkrvars.hcl` blocked
  (except `example.pkrvars.hcl`), plus `windows-keys.json`, `.nexus/`,
  `secrets/`.

### Canon references

- [ADR-0144 — Windows licensing posture](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md)
- [nexus-platform-plan docs/infra/licensing.md](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/licensing.md)

### Deferred

- Full Packer template bodies for `ws2025-core`, `ws2025-desktop`, `win11ent`
  (the licensing wiring specified in this release will be realized when
  those templates are written in Phase 0.B.4–0.B.6).
- Vault policy + AppRole for `packer-builder` (Phase 0.D).

## [0.1.0] — 2026-04-21 — "Phase 0.B scaffold + nexus-gateway build path"

Initial commit. Implements the scaffold for NexusPlatform infrastructure-as-code on VMware Workstation Pro and the full build/deploy path for **VM #0 `nexus-gateway`** (lab edge router).

### Added

- **Repo scaffold** — `packer/` with subdirs for all 6 golden templates; `terraform/gateway/` + `terraform/modules/vm/`; `docs/`; `.github/workflows/packer-validate.yml`; top-level `Makefile`.
- **`packer/nexus-gateway/`** — complete build path:
  - `nexus-gateway.pkr.hcl` — `vmware-iso` + `ansible-local` build, pinned Debian 13 netinst ISO, headless
  - `variables.pkr.hcl` — tunables (CPU, RAM, disk, ISO URL/checksum)
  - `http/preseed.cfg` — non-interactive Debian install (no GUI, sudo user, SSH, nftables/dnsmasq/chrony packages)
  - `files/nftables.conf` — ruleset (masquerade 192.168.70.0/24 → NIC0; drop VMnet10 egress)
  - `files/dnsmasq.conf` — DHCP .200-.250 + DNS forwarder (1.1.1.1/9.9.9.9) with DNSSEC
  - `files/chrony.conf` — public pool sources; serves lab on VMnet10/11 only
  - `ansible/playbook.yml` + `roles/nexus_gateway/` — persistent NIC naming via systemd .link, IP forwarding sysctl, ruleset install, services enabled, unattended security updates, SSH hardening, MOTD
- **`terraform/gateway/`** — root module:
  - `main.tf` — `vmworkstation_vm` resource + `null_resource` for NIC mapping + `null_resource` for power-on
  - `variables.tf` / `outputs.tf` / `example.tfvars`
- **`scripts/configure-gateway-nics.ps1`** — idempotent VMX rewriter: `ethernet0=bridged`, `ethernet1=VMnet11`, `ethernet2=VMnet10`, static MACs for stable NIC naming.
- **`.github/workflows/packer-validate.yml`** — CI: `packer init`/`fmt`/`validate -syntax-only`, `terraform fmt`/`validate`, `ansible-lint`, `shellcheck`.
- **`Makefile`** — `gateway`, `gateway-apply`, `gateway-destroy`, `validate`, `clean` targets. Stubs for the other 5 OS templates.
- **Docs** —
  - `README.md` — repo overview + quick start
  - `docs/architecture.md` — design rationale (toolchain, state, secrets, layering)
  - `docs/nexus-gateway.md` — VM #0 deep-dive + runbook (build, deploy, verify, rebuild)

### Canon references

- Implements [Phase 0.B.1](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) of nexus-platform-plan v0.1.2.
- Honors platform constraints from nexus-platform-plan [`docs/infra/network.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/network.md): Host-Only VMnet11, `192.168.70.1` = nexus-gateway, `192.168.70.254` = host, single-NAT-slot limit.

### Deferred to later phases

- Vault PKI integration for SSH CA + TLS (Phase 0.D).
- Tier-1 HA pattern for nexus-gateway (ADR-0142).
- Templates for `deb13`, `ubuntu24`, `ws2025-core`, `ws2025-desktop`, `win11ent` (Phase 0.B.2–0.B.6).
- Reusable `terraform/modules/vm/` contents (Phase 0.C).
