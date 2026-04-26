# packer/win11ent — Windows 11 Enterprise workstation (Phase 0.B.6)

**Status:** scaffolded.

Used for: nexus-desk integration testing, Windows-client portfolio demos
(WinForms/WPF/WinUI 3 apps), developer workstations.

Automated install via `Autounattend.xml` (shared `_shared/powershell/floppy/`
template). Post-install provisioning over WinRM, runtime access via OpenSSH
(installed by `01-nexus-identity.ps1`).

## What this template carries

Shared baseline (same as WS2025 templates):
- `nexusadmin` local admin + authorized_keys
- OpenSSH server + windows_exporter on `:9182`
- Windows Update policy, telemetry minimised, TLS 1.2+ only
- Firewall rules constrained to VMnet11

Win11 delta (`scripts/10-win11ent-client-tools.ps1`, winget-driven):
- .NET 10 SDK + .NET 10 Desktop Runtime
- Windows App SDK runtime (WinUI 3)
- Windows Terminal

VS Code is **not** installed at template-time — it's a per-user tool, not
a fleet baseline; clones layer it via Ansible if needed.

## TPM 2.0 + Secure Boot + UEFI

Win11 enforces all three at install. We provide them via VMware
Workstation's "software" vTPM (`managedvm.autoAddVTPM = "software"` in
`vmx_data`) plus `uefi.secureBoot.enabled = "TRUE"` and `firmware = "efi"`.
The VM uses **TPM-only encryption** (`encryption.required = "FALSE"`) — only
the `.nvram` (vTPM key blob) is encrypted on disk. The `.vmx` / `.vmdk`
remain plaintext so Packer manifest reads and Terraform clone flows work
without encryption-key distribution. Trade-off documented inline in
[win11ent.pkr.hcl](win11ent.pkr.hcl).

## Build / smoke

```pwsh
make win11ent              # evaluation ISO (default)
make win11ent-msdn         # retail/MSDN ISO + bootstrap key (owner-only)
make win11ent-smoke        # clone the template via modules/vm/
make win11ent-smoke-destroy
```

## Licensing — `product_source` contract

See [`docs/licensing.md`](../../docs/licensing.md) and
[ADR-0144](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md).

| Variable | Default | `msdn` | `evaluation` |
|---|---|---|---|
| `product_source` | `"evaluation"` | — | — |
| `image_name` (derived) | — | `Windows 11 Enterprise` | `Windows 11 Enterprise Evaluation` |
| `product_key` (derived) | — | Vault `nexus/windows/product-keys/win11ent` → `key` | `""` |

Win11 Enterprise Evaluation is 90 days, rearm-able (fewer rearms than
Server). Rebuild cadence via `make win11ent` is the canonical answer to
nearing-expiry VMs — see `docs/licensing.md` for the rearm automation.
`Autounattend.xml` is gitignored; only the shared `.tpl` is versioned.

## Smoke-test exit gate

Per `terraform/win11ent-smoke/`: clone DHCPs from `nexus-gateway`,
OpenSSH (`:22`) reachable, `windows_exporter` (`:9182`) returns metrics,
`dotnet --version` returns `10.x.y`, and `wt.exe` is on PATH. Domain join
and BitLocker enrollment are deferred to the nexus-desk role overlay —
this template stays generic.
