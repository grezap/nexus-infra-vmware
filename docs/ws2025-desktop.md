# ws2025-desktop — Windows Server 2025 Desktop Experience template

**Phase:** 0.B.5 · **Builds:** `Push-Location packer\ws2025-desktop; packer build .; Pop-Location` · **Smoke:** `Push-Location terraform\ws2025-desktop-smoke; terraform apply -auto-approve; Pop-Location` · *(Linux/WSL/CI: `make ws2025-desktop` / `make ws2025-desktop-smoke`)*

Sibling of [`ws2025-core`](ws2025-core.md). The two templates share everything under [`packer/_shared/powershell/`](../packer/_shared/powershell/) — Autounattend template, identity/network/firewall/observability/baseline/sysprep scripts, the `nexusadmin` authorized_keys file. They diverge on three axes:

1. **install.wim image name** — Setup picks the Desktop Experience SKU instead of Core. Names are baked into Autounattend at templatefile() render time, which is why a separate `.pkr.hcl` exists rather than a single parameterised template.
2. **Hardware defaults** — Desktop Experience needs ~16 GB on disk (vs 10 GB for Core) plus 4-8 GB RAM headroom for an interactive admin session, so the template defaults to `memory_mb=6144` / `disk_gb=80`.
3. **Desktop-admin delta** — `scripts/10-desktop-admin-tools.ps1` installs RSAT-AD-Tools + RSAT-DNS-Server + RSAT-DHCP + GPMC. This is the entire reason Desktop Experience exists in this fleet: the upcoming `dc-nexus` role and any admin jump box need MMC snap-ins to run locally.

## DRY pass at this phase

When ws2025-core landed at Phase 0.B.4, the eight provisioner scripts and the Autounattend template lived under `packer/ws2025-core/`. Phase 0.B.5 (this template) triggered the DRY extraction per the same two-call-sites rule that drove the Linux extraction at 0.B.3:

```
packer/_shared/powershell/
├── files/nexusadmin-authorized_keys
├── floppy/Autounattend.xml.tpl
└── scripts/
    ├── bootstrap-winrm.ps1
    ├── 00-install-vmware-tools.ps1
    ├── 01-nexus-identity.ps1
    ├── 02-nexus-network.ps1
    ├── 03-nexus-firewall.ps1
    ├── 04-nexus-observability.ps1
    ├── 05-windows-baseline.ps1
    └── 99-sysprep.ps1
```

Both `packer/ws2025-core/ws2025-core.pkr.hcl` and `packer/ws2025-desktop/ws2025-desktop.pkr.hcl` reference these via relative `${path.root}/../_shared/powershell/...` paths. New Windows templates (e.g. `win11ent` at Phase 0.B.6) reuse the same shared bundle and only add their own delta scripts under their own `scripts/` directory.

## Smoke verification

`terraform/ws2025-desktop-smoke/` clones the template onto VMnet11 with MAC `00:50:56:3F:00:23` (one above ws2025-core-smoke's `:22`). Exit gate is the same as ws2025-core-smoke (SSH + windows_exporter responding) plus a check that the Desktop Experience delta features are present:

```powershell
# Assumes handbook §0.4 SSH client setup; otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519`.
# Win32-OpenSSH default remote shell is cmd.exe -- wrap PowerShell-style commands explicitly.
ssh nexusadmin@<vm-ip> 'powershell -NoProfile -Command "Get-WindowsFeature RSAT-AD-Tools, RSAT-DNS-Server, RSAT-DHCP, GPMC | Format-Table Name, InstallState"'
```

All four should report `Installed`.

## Licensing

Identical contract to `ws2025-core` (see [`docs/licensing.md`](licensing.md)). Vault path differs: `nexus/windows/product-keys/ws2025-desktop` instead of `…/ws2025-core`. The pre-Phase-0.D bootstrap JSON must contain a `ws2025-desktop` entry with a `key` field — same file format, two entries for the two templates.
