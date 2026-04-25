# packer/ws2025-desktop — Windows Server 2025 Desktop Experience (Phase 0.B.5)

**Status:** Phase 0.B.5 — implemented. Sibling of [`packer/ws2025-core`](../ws2025-core/), shares the entire baseline under [`packer/_shared/powershell/`](../_shared/powershell/) (DRY extracted at this phase per the two-call-sites rule that drove the Linux `_shared/ansible/roles/` extraction at 0.B.3).

Used for: Active Directory domain controller (`dc-nexus`), admin jump boxes requiring RSAT tooling / ADUC / GPMC / DNS Manager.

## What it adds over `ws2025-core`

| Aspect | ws2025-core | ws2025-desktop |
|---|---|---|
| `install.wim` image name (eval) | `Windows Server 2025 Standard Evaluation` | `Windows Server 2025 Standard Evaluation (Desktop Experience)` |
| `install.wim` image name (msdn) | `Windows Server 2025 Standard` | `Windows Server 2025 Standard (Desktop Experience)` |
| Default `memory_mb` | 4096 | 6144 |
| Default `disk_gb` | 60 | 80 |
| Extra provisioner | — | `scripts/10-desktop-admin-tools.ps1` (RSAT-AD-Tools, RSAT-DNS-Server, RSAT-DHCP, GPMC) |

Everything else (NIC rename to `nic0`, OpenSSH Server, windows_exporter on `:9182`, Windows Firewall baseline, login banner, deferred-sysprep teardown) is identical — provisioned via the same shared scripts under `packer/_shared/powershell/scripts/`.

Exit gate: fresh clone is reachable on VMnet11 via OpenSSH + windows_exporter (smoke test parity with `ws2025-core`), and `Get-WindowsFeature RSAT-AD-Tools, RSAT-DNS-Server, RSAT-DHCP, GPMC` reports `Installed`. Domain promotion (`Install-ADDSForest`) is **not** done here — that lives in the future `dc-nexus` role overlay.

## Licensing — `product_source` contract

See [`docs/licensing.md`](../../docs/licensing.md) and [ADR-0144](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md). Identical to `ws2025-core` apart from the Vault path.

| Variable | Default | `msdn` | `evaluation` |
|---|---|---|---|
| `product_source` | `"evaluation"` | — | — |
| `edition` (derived) | — | `ServerStandard (Desktop Experience)` | `ServerStandardEval (Desktop Experience)` |
| `product_key` (derived) | `""` | Vault `nexus/windows/product-keys/ws2025-desktop` → `key` (post-0.D) or `bootstrap_keys_file` JSON (pre-0.D) | `""` |

## Build / smoke

```pwsh
make ws2025-desktop                # evaluation ISO (default, public path)
make ws2025-desktop-msdn           # owner path: retail ISO + bootstrap key
make ws2025-desktop-smoke          # clone via terraform/modules/vm/ + verify
make ws2025-desktop-smoke-destroy  # tear down
```
