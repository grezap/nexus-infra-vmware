# packer/ws2025-core — Windows Server 2025 Core (Phase 0.B.4)

**Status:** implemented.

Full runbook in [`docs/ws2025-core.md`](../../docs/ws2025-core.md). This README is a quick-reference cheat sheet.

```
packer/ws2025-core/
├── ws2025-core.pkr.hcl                    # vmware-iso + WinRM + floppy Autounattend
└── variables.pkr.hcl                      # ISO paths + product_source + tunables

packer/_shared/powershell/                 # DRY-extracted at Phase 0.B.5 (shared with ws2025-desktop)
├── floppy/
│   └── Autounattend.xml.tpl               # templatefile() renders into floppy_content
├── scripts/
│   ├── bootstrap-winrm.ps1                # runs at OOBE FirstLogonCommand (on floppy as A:\)
│   ├── 00-install-vmware-tools.ps1
│   ├── 01-nexus-identity.ps1              # nexusadmin + OpenSSH + authorized_keys + sshd hardening
│   ├── 02-nexus-network.ps1               # NIC rename nic0 + W32Time + DNS
│   ├── 03-nexus-firewall.ps1              # default-deny inbound + VMnet11 allowlist
│   ├── 04-nexus-observability.ps1         # windows_exporter 0.30.4 on :9182
│   ├── 05-windows-baseline.ps1            # WU policy, telemetry, TLS, banner, pagefile
│   └── 99-sysprep.ps1                     # teardown build listener + generalize + shutdown
└── files/
    └── nexusadmin-authorized_keys         # owner ed25519 pubkey
```

## Quickstart

```powershell
# Evaluation path (default — 180-day eval, no product key):
make ws2025-core
make ws2025-core-smoke
make ws2025-core-smoke-destroy

# MSDN path (owner only, requires bootstrap JSON with product key):
make ws2025-core-msdn
```

## Licensing — `product_source` contract

See [`docs/licensing.md`](../../docs/licensing.md) and ADR-0144. Summary:

| Variable                | `evaluation` (default) | `msdn` (owner)                                             |
|-------------------------|------------------------|------------------------------------------------------------|
| ISO                     | `WindowsServer2025Evaluation.iso` | `WindowsServer2025.iso`                         |
| `image_name` (derived)  | `Windows Server 2025 Standard Evaluation` | `Windows Server 2025 Standard`           |
| `product_key` (derived) | `""`                   | Read from `bootstrap_keys_file` JSON (pre-0.D) or Vault     |

`Autounattend.xml` is rendered *in-memory* by Packer's `templatefile()` and streamed directly to the floppy image — **never written to disk on the build host**, so no gitignored artifact sits around holding a key. Only the `.tpl` is committed.

## Why PowerShell scripts (not Ansible)

The Phase 0.B.3 `_shared/ansible/roles/nexus_*` roles are Linux-specific (systemd, nftables, systemd-networkd, chrony). Windows needs a parallel set using Windows-native mechanisms (Windows Firewall, W32Time, netsh, Rename-NetAdapter, windows_exporter MSI). Rather than introduce a Windows Ansible dependency on the build host (pywinrm, ansible-for-windows, WSL, …), we use PowerShell provisioners directly. The script names (`01-nexus-identity`, `02-nexus-network`, …) mirror the Linux role names so the parallel is legible.

DRY extraction into `packer/_shared/powershell/` happens when `ws2025-desktop` lands (Phase 0.B.5) — two call sites, same two-call-sites rule as Linux.
