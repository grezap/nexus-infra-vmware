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

## Win11 install hardware-check bypass

Win11 Setup enforces TPM 2.0 + Secure Boot + 4 GB RAM at install. The
template runs on standalone VMware Workstation, which cannot expose a
real vTPM to Packer headlessly: `managedvm.autoAddVTPM = "software"` is
a vSphere managed-VM construct that Workstation ignores, and the only
documented Workstation paths to a real vTPM (interactive encryption
password or a preconfigured KMIP key safe) don't fit a Packer flow.

We bypass the install-time gate by writing three regkeys in the
windowsPE pass via Autounattend `RunSynchronousCommand`:

```
HKLM\SYSTEM\Setup\LabConfig\BypassTPMCheck       = 1
HKLM\SYSTEM\Setup\LabConfig\BypassSecureBootCheck = 1
HKLM\SYSTEM\Setup\LabConfig\BypassRAMCheck        = 1
```

**Implications for clones:** the OS has no TPM device. BitLocker remains
available in recovery-key mode but cannot use TPM-backed protection.
Windows Update keeps working but may flag the device as ineligible for
some future feature updates. For the nexus-desk dev/test workload
(.NET 10 SDK, WinAppSDK demos, Terminal) this is functionally
indistinguishable from a Win11 install on real TPM hardware.

Real vTPM is deferred to Phase 0.D, when Vault + KMIP land and we
have a path for headless encryption-key distribution.

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
