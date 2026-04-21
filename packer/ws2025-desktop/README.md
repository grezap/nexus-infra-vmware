# packer/ws2025-desktop — Windows Server 2025 Desktop Experience (Phase 0.B.5)

**Status:** stub.

Used for: Active Directory domain controller (`dc-nexus`), admin jump boxes requiring RSAT tooling / ADUC / GPMC.

Same Autounattend + Ansible `windows_base` role as `ws2025-core`, plus:

- RSAT feature bundle
- Group Policy Management Console
- DNS / DHCP Server tools (for the DC role)
- Edge + basic productivity tools (for admin convenience)

Exit gate: fresh clone can be promoted to DC for `nexus.local` domain and serves DNS/LDAP.
