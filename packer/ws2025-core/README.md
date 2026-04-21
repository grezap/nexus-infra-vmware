# packer/ws2025-core — Windows Server 2025 Core (Phase 0.B.4)

**Status:** stub.

Headless Windows server image for: SQL Server 2022 FCI + AG nodes, service hosts that don't need a GUI.

Automated install via `Autounattend.xml` delivered on a secondary floppy/ISO. Post-install provisioning via WinRM + Ansible (`ansible.windows`). Features to preinstall:

- PowerShell 7+ (replaces built-in 5.1 for new automation)
- Windows Admin Center agent (where applicable)
- OpenSSH Server
- Windows Defender baseline matching CIS L1
- Prometheus `windows_exporter`
- Domain-join stub (completes at Terraform apply time once AD is up)
- Vault PowerShell module (Phase 0.D)

Ansible role: `windows_base`. Shared with `ws2025-desktop` and `win11ent` via `packer/_shared/ansible/roles/windows_base/`.

Exit gate: fresh clone can be domain-joined to `nexus.local` and pulls its node_exporter scrape into Prometheus.

## Licensing — `product_source` contract

See [`docs/licensing.md`](../../docs/licensing.md) and
[ADR-0144](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md)
for the canonical story. Summary for this template:

| Variable | Default | `msdn` | `evaluation` |
|---|---|---|---|
| `product_source` | `"evaluation"` | — | — |
| `edition` (derived) | — | `ServerStandard` | `ServerStandardEval` |
| `product_key` (derived) | — | Vault `nexus/windows/product-keys/ws2025-core` → `key` (or bootstrap JSON pre-Phase-0.D) | `""` |

Build:

```bash
packer build packer/ws2025-core                          # public / cloner
packer build -var product_source=msdn packer/ws2025-core # owner with MSDN + Vault
```

**Never commit `Autounattend.xml`** — only `Autounattend.xml.tpl`. The
rendered form contains `<ProductKey>` inline and is gitignored at every path.
