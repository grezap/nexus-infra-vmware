# packer/ws2025-desktop — Windows Server 2025 Desktop Experience (Phase 0.B.5)

**Status:** stub.

Used for: Active Directory domain controller (`dc-nexus`), admin jump boxes requiring RSAT tooling / ADUC / GPMC.

Same Autounattend + Ansible `windows_base` role as `ws2025-core`, plus:

- RSAT feature bundle
- Group Policy Management Console
- DNS / DHCP Server tools (for the DC role)
- Edge + basic productivity tools (for admin convenience)

Exit gate: fresh clone can be promoted to DC for `nexus.local` domain and serves DNS/LDAP.

## Licensing — `product_source` contract

See [`docs/licensing.md`](../../docs/licensing.md) and
[ADR-0144](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md).

| Variable | Default | `msdn` | `evaluation` |
|---|---|---|---|
| `product_source` | `"evaluation"` | — | — |
| `edition` (derived) | — | `ServerStandard` | `ServerStandardEval` |
| `product_key` (derived) | — | Vault `nexus/windows/product-keys/ws2025-desktop` → `key` | `""` |

Eval edition shows a small bottom-right watermark (functionality unaffected).
Owner builds on host `10.0.70.101` use `-var product_source=msdn` and read
from Vault. `Autounattend.xml` is gitignored; only the `.tpl` is versioned.
