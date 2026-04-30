# ws2025-core — design + runbook

**Windows Server 2025 Core base template.** First Windows image in the lab — parent for VMs that need Windows userspace without a desktop (SQL Server FCI + AG nodes, Windows-specific service hosts, IIS-backed legacy integration, .NET Framework workloads). Parallel in intent to [`deb13`](./deb13.md) and [`ubuntu24`](./ubuntu24.md), but every implementation detail differs because the OS differs.

## Why Core (not Desktop Experience)

Most Windows workloads in the lab (SQL Server, windows_exporter, OpenSSH, Defender) don't need a GUI. Core's footprint is ~11 GB vs ~25 GB for Desktop Experience — materially smaller backing-store per clone. Clones that do need the GUI (owner admin jump host, Windows-GUI apps) will come from `ws2025-desktop` (Phase 0.B.5).

## What the template ships

| Component                                | Status at build time | Notes |
|------------------------------------------|----------------------|-------|
| WS2025 Standard (Core)                   | Installed via Autounattend.xml | Image name `Windows Server 2025 Standard Evaluation` (eval ISO) or `Windows Server 2025 Standard` (MSDN ISO) — selected by `product_source` var |
| VMware Tools                             | Silent install from Workstation's `windows.iso` | Mounted from `C:\Windows\Temp\windows.iso` during build, removed after install |
| `nexusadmin` local admin                 | Created by Autounattend, reconciled by `01-nexus-identity.ps1` | Owner ed25519 pubkey in `administrators_authorized_keys` (the path Windows OpenSSH actually reads for admin users — `~/.ssh/authorized_keys` is ignored for admins) |
| OpenSSH Server (WindowsCapability)       | Enabled + sshd_config hardened | PubkeyAuth only, AllowUsers nexusadmin, PermitRootLogin no |
| NIC rename → `nic0`                      | Renamed via `Rename-NetAdapter`           | Matches Linux templates' `en*→nic0` convention for consistent Prometheus labels |
| W32Time → 192.168.70.1                   | `/manualpeerlist` points at gateway with `time.windows.com` fallback | Windows equivalent of chrony client |
| Windows Firewall baseline                | Default-deny inbound; SSH/WinRM-HTTPS/9182/RDP/ICMPv4 allowed from VMnet11 only | Parallel to nftables on Linux |
| `windows_exporter` 0.30.4                | MSI install, `:9182`, service Automatic | Parallel to `prometheus-node-exporter` — collectors: cpu, cs, logical_disk, memory, net, os, service, system, tcp, textfile |
| Windows Defender + TLS hardening         | SSL 2/3 + TLS 1.0/1.1 disabled at SCHANNEL | Locked to TLS 1.2/1.3 |
| Login banner (LegalNotice)               | NexusPlatform frame at Ctrl-Alt-Del          | Windows equivalent of `/etc/motd` |
| Telemetry                                | `AllowTelemetry = 0` (Security-only) | Lowest possible on WS Standard |
| Pagefile                                 | Fixed 4 GB (not system-managed) | Predictable disk usage for thin-clone math |
| Build-time WinRM listener                | Torn down before sysprep       | Runtime remote access is OpenSSH only |
| Sysprep `/generalize /oobe /shutdown`    | Runs in `99-sysprep.ps1`       | Fresh SID on every clone; OOBE skipped via inline unattend |

## What the template does **not** ship

- No Ansible. The Phase 0.B.3 `_shared/ansible/roles/nexus_*` roles are Linux-native (systemd, nftables, systemd-networkd, chrony). Windows has the parallel PowerShell scripts under `scripts/`; the DRY extraction waits for ws2025-desktop (Phase 0.B.5) — same two-call-sites rule as Linux.
- No domain-join. Kept explicit — `nexus.local` AD isn't up until Phase 0.F. A Terraform data source + Ansible playbook will join role VMs after that.
- No SQL Server, no IIS, no .NET Framework overlay — role overlays add those per-VM.
- No Server Manager auto-launch, no CEIP, no Customer Experience Improvement tasks.

## Licensing — two ISOs, two paths

See [`docs/licensing.md`](./licensing.md) and ADR-0144 for the full story. TL;DR:

| `product_source`   | ISO path                                            | Image name                                   | Key                                |
|--------------------|-----------------------------------------------------|----------------------------------------------|------------------------------------|
| `evaluation` (default) | `H:/VMS/ISO/WindowsServer2025Evaluation.iso`    | `Windows Server 2025 Standard Evaluation`    | None (180-day eval, rearm-able)    |
| `msdn`             | `H:/VMS/ISO/WindowsServer2025.iso`                  | `Windows Server 2025 Standard`               | `bootstrap_keys_file` JSON (pre-0.D) or Vault (post-0.D) |

The ISO-SHA256 pairs are pinned in `variables.pkr.hcl`; rotate when ISOs are re-downloaded.

## Build + deploy

Prerequisites:
- Phase 0.B.1 complete (nexus-gateway running at 192.168.70.1).
- WS2025 Evaluation ISO at `H:/VMS/ISO/WindowsServer2025Evaluation.iso` (default path).
- `H:/VMS/NexusPlatform/_templates/` directory writable.

```powershell
cd "F:\_CODING_\…\nexus-infra-vmware"

# 1. Build the template — evaluation path, no key required (~35-45 min;
#    Windows Setup alone is ~15 min, then 25-30 min of provisioning)
Push-Location packer\ws2025-core; packer build .; Pop-Location
# Template lands at H:\VMS\NexusPlatform\_templates\ws2025-core\ws2025-core.vmx

# 1b. MSDN path (owner only, requires bootstrap JSON)
Push-Location packer\ws2025-core
packer build `
    -var "product_source=msdn" `
    -var "bootstrap_keys_file=$env:USERPROFILE/.nexus/secrets/windows-keys.json" .
Pop-Location

# 2. Smoke-test via the reusable module (~10 sec terraform + 30-60 sec boot)
Push-Location terraform\ws2025-core-smoke; terraform apply -auto-approve; Pop-Location
# VM lands at H:\VMS\NexusPlatform\90-smoke\ws2025-core-smoke\ws2025-core-smoke.vmx

# 3. Find its DHCP lease (from nexus-gateway's dnsmasq)
#    Assumes handbook §0.4 SSH client setup; otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519`.
ssh nexusadmin@192.168.70.1 "awk '\$2==\"00:50:56:3f:00:22\" {print \$3}' /var/lib/misc/dnsmasq.leases"

# 4. Probe it
Test-NetConnection <ip> -Port 22      # OpenSSH
Test-NetConnection <ip> -Port 9182    # windows_exporter
# Win32-OpenSSH default remote shell is cmd.exe -- wrap PowerShell-style commands explicitly.
ssh nexusadmin@<ip> 'powershell -NoProfile -Command "hostname; (Get-Service sshd, windows_exporter).Status"'

# 5. Tear down
Push-Location terraform\ws2025-core-smoke; terraform destroy -auto-approve; Pop-Location
```

> Linux/WSL/CI users can substitute the equivalent `make ws2025-core` / `make ws2025-core-msdn` / `make ws2025-core-smoke` / `make ws2025-core-smoke-destroy` Makefile targets. GNU make is not installed on the canonical Windows build host -- the pwsh-native commands above are canonical there per [`memory/feedback_build_host_pwsh_native.md`](../memory/feedback_build_host_pwsh_native.md).

## Verification checklist

From inside the smoke-test VM (over SSH):

```powershell
# NIC renamed correctly
Get-NetAdapter                        # expect name = nic0, status = Up, DHCP IP in 192.168.70.200-.250

# Time sync pointed at the gateway
w32tm /query /peers                   # expect 192.168.70.1 as primary peer

# Firewall baseline
Get-NetFirewallProfile | Select Name,Enabled,DefaultInboundAction
Get-NetFirewallRule -Name 'Nexus-*'   # expect SSH, windows_exporter, RDP, ICMPv4 rules present

# windows_exporter responding
Invoke-WebRequest http://localhost:9182/metrics -UseBasicParsing |
  Select-Object -ExpandProperty Content |
  Select-String '^windows_(cpu|os|system)' | Select-Object -First 10

# DNS via the gateway
Resolve-DnsName one.one.one.one
Get-DnsClientServerAddress -InterfaceAlias nic0  # primary should be 192.168.70.1

# Login banner — look at Ctrl-Alt-Del screen (console) or regkey
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').LegalNoticeCaption

# Sysprep fresh SID — should be unique per clone
(Get-CimInstance Win32_ComputerSystemProduct).UUID
```

## Design decisions worth remembering

### Why WinRM for build, OpenSSH for runtime

WinRM is the standard Packer-for-Windows communicator — battle-tested, well-documented, fast. But it requires a listener, authentication config, and firewall rule that are awkward to leave running at runtime. OpenSSH Server ships as a Windows Capability on WS2025, uses key-only auth, matches every other NexusPlatform VM's remote-access convention, and gets the same tooling treatment (ssh-keygen rotation, AllowUsers, MaxAuthTries).

So: WinRM is a build-only channel, torn down by `99-sysprep.ps1`. SSH is the runtime channel. The autounattend FirstLogonCommand opens WinRM; the last provisioner step closes it.

### Windows's two-file authorized_keys quirk

For admin users, Windows OpenSSH reads `C:\ProgramData\ssh\administrators_authorized_keys` (ACL-locked to SYSTEM + Administrators) — not `~/.ssh/authorized_keys`. If you deploy your key only to the user-profile file, sshd silently ignores it and prompts for password auth. `01-nexus-identity.ps1` writes to both paths (profile for future non-admin usage, admin path for the immediate nexusadmin login) and ACL-locks both. Forgetting this quirk is the #1 cause of "I enabled OpenSSH but it keeps rejecting my key."

### Floppy-delivered Autounattend (not HTTP)

Windows Setup auto-discovers `Autounattend.xml` on attached removable media before checking the network. We deliver it via Packer's `floppy_content` (rendered from `.tpl` via `templatefile()` with the product key inlined — never written to the build-host disk). No HTTP server races, no preseed-URL brittleness. Same pattern as the rest of the Windows Packer community.

### UEFI + GPT (not BIOS + MBR)

WS2025's Setup refuses legacy BIOS on recent builds. Source is `firmware = "efi"`; Autounattend creates an EFI System Partition (260 MB) + Microsoft Reserved Partition (128 MB) + OS partition (growable). Matches modern physical hardware and makes future Secure Boot / BitLocker stories possible.

### No shared Windows roles (yet)

The Phase 0.B.3 lesson was that abstractions need two concrete callers before extraction. With only `ws2025-core` we'd be guessing. `ws2025-desktop` (Phase 0.B.5) provides the second caller; the extraction target is likely `packer/_shared/powershell/modules/` with a `NexusIdentity.psm1`, `NexusNetwork.psm1`, etc., or a `_shared/scripts/windows/` directory.

### Build-time WinRM = HTTP + Basic + Unencrypted

Yes, really. This is Packer-for-Windows's canonical build-time config — plaintext WinRM inside the NAT network during a ~35-minute single-VM build. The risk window is small and contained, and `99-sysprep.ps1` removes the listener entirely before the template is finalized. Runtime WinRM (if ever needed) would use HTTPS + cert auth via Vault PKI in Phase 0.D.

### Pagefile fixed at 4 GB

Windows's "system-managed" pagefile grows unpredictably (up to 3× RAM). On thin-provisioned clones this causes surprise disk consumption. Fixing at 4 GB gives predictable backing-store math without starving the OS.

## Rebuild procedure

```powershell
cd "F:\_CODING_\…\nexus-infra-vmware"
Push-Location terraform\ws2025-core-smoke; terraform destroy -auto-approve; Pop-Location   # if a smoke VM exists
Remove-Item -Recurse -Force H:\VMS\NexusPlatform\_templates\ws2025-core -ErrorAction SilentlyContinue
Push-Location packer\ws2025-core;          packer build .;                Pop-Location     # rebuild template
Push-Location terraform\ws2025-core-smoke; terraform apply -auto-approve; Pop-Location     # verify
```

## Known gotchas (real ones, from first build)

*(This section will fill in as the first build surfaces issues — autounattend tuning, sysprep edge cases, Tools install timing, etc. See the git log around the Phase 0.B.4 commits for actual failure modes and fixes.)*
