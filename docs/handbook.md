# NexusPlatform operator handbook

A command-reference cheat sheet for rebuilding the lab from cold metal. Per-VM design docs live alongside this file (e.g. [nexus-gateway.md](nexus-gateway.md)); this handbook is the **cross-cutting ops manual** — host prep, day-to-day commands, common-failure triage.

All commands assume **PowerShell 7+ (`pwsh`)** on the Windows host unless noted otherwise. Repo root: `F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware`.

---

## 0. One-time host prep

Do these once, in order, before building any VM.

### 0.1 Install toolchain

```powershell
winget install -e --id HashiCorp.Packer
winget install -e --id HashiCorp.Terraform
# VMware Workstation Pro 17.6+ installed separately (requires Broadcom account)
```

Verify:

```powershell
packer version      # expect >= 1.11
terraform version   # expect >= 1.9
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' -T ws list
```

### 0.2 Create VMnet10 + VMnet11 (Phase 0.A — host-only networks)

Use Workstation's **Virtual Network Editor** (Edit → Virtual Network Editor → Change Settings — elevation required):

| Name     | Type      | Subnet             | DHCP | Host adapter IP   |
|----------|-----------|--------------------|------|-------------------|
| VMnet10  | Host-only | `192.168.10.0/24`  | OFF  | `192.168.10.254`  |
| VMnet11  | Host-only | `192.168.70.0/24`  | OFF  | `192.168.70.254`  |

Verify host adapters exist:

```powershell
Get-NetAdapter -Name 'VMware Network Adapter VMnet1*'
Get-NetIPAddress -InterfaceAlias 'VMware Network Adapter VMnet11'  # should be 192.168.70.254
Get-NetIPAddress -InterfaceAlias 'VMware Network Adapter VMnet10'  # should be 192.168.10.254
```

### 0.3 Clone the repo + init

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace"
git clone git@github.com:grezap/nexus-infra-vmware.git
cd nexus-infra-vmware
make init   # runs packer init + terraform init for gateway
```

---

## 1. Phase 0.B.1 — nexus-gateway (VM #0)

Full deep-dive: [`docs/nexus-gateway.md`](nexus-gateway.md).

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware"

# Build the template (~7 min)
make gateway

# Deploy the running instance (~7 sec)
make gateway-apply

# Sanity check
Test-NetConnection 192.168.70.1 -Port 53
Test-NetConnection 192.168.70.1 -Port 22
nslookup one.one.one.one 192.168.70.1

# Tear down (destroys instance, template survives)
make gateway-destroy
```

**If the destination path already exists** before `make gateway`, wipe it first so Packer doesn't conflate runs:

```powershell
Remove-Item -Recurse -Force H:\VMS\NexusPlatform\_templates\nexus-gateway -ErrorAction SilentlyContinue
```

**If Terraform state got corrupted** (e.g. half-destroyed):

```powershell
cd terraform\gateway
Remove-Item -Recurse -Force .terraform, .terraform.lock.hcl, terraform.tfstate*
terraform init
terraform apply -auto-approve
```

---

## 1a. Phase 0.B.2 — deb13 generic base template

Full deep-dive: [`docs/deb13.md`](deb13.md). Parent image for ~60 of the 65 lab VMs.

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware"

# Build the template (~7–8 min)
make deb13
# Template lands at H:\VMS\NexusPlatform\_templates\deb13\deb13.vmx

# Smoke-test the template via terraform/modules/vm/ (~10 sec)
make deb13-smoke
# Clone lands at H:\VMS\NexusPlatform\90-smoke\deb13-smoke\deb13-smoke.vmx
# It will DHCP from nexus-gateway in 192.168.70.200-.250.

# Find its lease + probe
200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }
Test-NetConnection <ip> -Port 22
Test-NetConnection <ip> -Port 9100
ssh nexusadmin@<ip>

# Tear down
make deb13-smoke-destroy
```

### 1a.1 Rebuilding from scratch

```powershell
make deb13-smoke-destroy                                                       # if a smoke VM exists
Remove-Item -Recurse -Force H:\VMS\NexusPlatform\_templates\deb13 -ErrorAction SilentlyContinue
make deb13
make deb13-smoke                                                               # verify
```

### 1a.2 Reusing the module for real role VMs

Every non-gateway VM will call `terraform/modules/vm/`:

```hcl
module "my_postgres" {
  source            = "../modules/vm"
  vm_name           = "my-postgres"
  template_vmx_path = "H:/VMS/NexusPlatform/_templates/deb13/deb13.vmx"
  vm_output_dir     = "H:/VMS/NexusPlatform/20-data/my-postgres"
  mac_address       = "00:50:56:3F:00:30"   # :30-3F = data tier
  # vnet defaults to VMnet11
}
```

MAC allocation convention (fourth byte of `00:50:56:3F:XX:YY`):

| Range  | Tier     | Example consumers             |
|--------|----------|-------------------------------|
| `:10-1F` | edge     | nexus-gateway                  |
| `:20-2F` | smoke    | deb13-smoke, ad-hoc test VMs   |
| `:30-3F` | data     | Postgres, Mongo, ClickHouse    |
| `:40-4F` | core     | Vault, Consul, Redis           |
| `:50-5F` | apps     | APIs, workers, Swarm nodes     |

See [`terraform/modules/vm/README.md`](../terraform/modules/vm/README.md).

### 1a.3 The gotcha worth remembering (Linux templates)

SSH host keys are wiped at Packer cleanup (so each clone gets unique keys) and regenerated on first boot via a `ssh.service.d/10-regenerate-host-keys.conf` drop-in. The drop-in **clears** the inherited `ExecStartPre` list before re-adding our own — without that, systemd's additive-append behavior runs the stock `sshd -t` before our `ssh-keygen -A`, `sshd -t` fails, and sshd never starts. Full story in [`docs/deb13.md`](deb13.md#ssh-host-keys-are-deliberately-removed-at-build-time--and-how-we-regenerate-them).

---

## 1b. Phase 0.B.4 — ws2025-core Windows Server 2025 Core template

Full deep-dive: [`docs/ws2025-core.md`](ws2025-core.md). First Windows image in the fleet.

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware"

# Build the template — evaluation path (default; 180-day eval, no product key).
# Eval ISO must be staged at H:/VMS/ISO/WindowsServer2025Evaluation.iso.
# First build is slow: ~15 min Setup + ~25 min PowerShell provisioning + Tools install.
make ws2025-core

# MSDN / retail path (owner only, requires bootstrap JSON with product key):
make ws2025-core-msdn

# Smoke-test
make ws2025-core-smoke
# VM lands at H:/VMS/NexusPlatform/90-smoke/ws2025-core-smoke/*.vmx

# Find its lease + SSH in
ssh nexusadmin@192.168.70.1 "awk '\$2==\"00:50:56:3f:00:22\" {print \$3}' /var/lib/misc/dnsmasq.leases"
Test-NetConnection <ip> -Port 22      # OpenSSH (key-only)
Test-NetConnection <ip> -Port 9182    # windows_exporter
ssh nexusadmin@<ip>                    # logs in via owner ed25519 pubkey

make ws2025-core-smoke-destroy
```

### 1b.1 The gotcha worth remembering (Windows template)

For admin users, Windows OpenSSH reads `C:\ProgramData\ssh\administrators_authorized_keys` — not `~/.ssh/authorized_keys`. If the pubkey is only in the user-profile file, sshd silently falls back to password auth (which 01-nexus-identity.ps1 has disabled) and every connection gets `Permission denied (publickey)`. The script writes to both paths and ACL-locks each. Full story in [`docs/ws2025-core.md`](ws2025-core.md#windowss-two-file-authorized_keys-quirk).

### 1b.2 Why PowerShell, not Ansible

The Linux shared roles (`nexus_identity`, `nexus_network`, `nexus_firewall`, `nexus_observability`) are systemd / nftables / chrony / node_exporter — every component is Linux-native. Windows has different primitives (Windows Firewall, W32Time, Windows Capabilities, windows_exporter MSI) and running Ansible against Windows requires either WSL + pywinrm on the build host or pulling Python into the template. Neither is worth the dependency weight for parity that's one-to-one with straight PowerShell. DRY extraction into `packer/_shared/powershell/` happens when `ws2025-desktop` (Phase 0.B.5) gives us a second concrete caller.

---

## 2. Working with the running gateway

### 2.1 SSH in

```powershell
ssh nexusadmin@192.168.70.1
# Prefer key auth — nexusadmin.pub is baked into the template's authorized_keys.
# Build-time password is set via packer/nexus-gateway/variables.pkr.hcl `ssh_password`
# default; rotated / removed in Phase 0.D when Vault comes up.
```

### 2.2 Add the VM to Workstation's GUI sidebar (cosmetic)

```
File → Open… → H:\VMS\NexusPlatform\00-edge\nexus-gateway\nexus-gateway.vmx
```

Workstation's library is a separate per-user inventory (`%APPDATA%\VMware\inventory.vmls`). `vmrun start` powers VMs on but does **not** register them in the library — adding them is optional.

### 2.3 Check what's running via `vmrun`

```powershell
$vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
& $vmrun list                                      # all running VMs (paths)
& $vmrun -T ws getGuestIPAddress <path-to-.vmx>    # reported guest IP (if tools installed)
& $vmrun -T ws stop   <path-to-.vmx> hard          # force power-off
& $vmrun -T ws start  <path-to-.vmx> nogui         # power on headless
& $vmrun -T ws reset  <path-to-.vmx> hard          # hard reboot
```

### 2.4 In-guest service inspection

```bash
systemctl status systemd-networkd dnsmasq nftables chrony prometheus-node-exporter
journalctl -u dnsmasq        -n 50 --no-pager
journalctl -u systemd-networkd -n 50 --no-pager
sudo nft list ruleset
ip -br link && ip -br addr
chronyc sources -v
```

---

## 3. Common host-side commands

### 3.1 Git

```powershell
git status
git log --oneline -20
git diff -- packer terraform
```

### 3.2 Terraform hygiene

```powershell
cd terraform\gateway
terraform fmt -recursive        # rewrite-in-place
terraform fmt -check -recursive # CI-style check (no writes)
terraform validate
terraform plan                  # preview without applying
terraform show                  # current state, human-readable
terraform state list            # resources under management
```

### 3.3 Packer hygiene

```powershell
cd packer\nexus-gateway
packer fmt -recursive .
packer validate .
packer inspect .                # show vars + builders + provisioners
```

### 3.4 Firewall / routing from host

```powershell
# Which interface will the host use to reach 192.168.70.1?
Find-NetRoute -RemoteIPAddress 192.168.70.1

# Port probe with explicit source interface
Test-NetConnection 192.168.70.1 -Port 53  # expect SourceAddress = 192.168.70.254

# Clear ARP cache if an old MAC is stuck
Get-NetNeighbor -AddressFamily IPv4 | Where-Object IPAddress -match '^192\.168\.70\.' | Remove-NetNeighbor -Confirm:$false
```

---

## 4. Troubleshooting recipes

### 4.1 "Ping to 192.168.70.1 failed" right after `terraform apply`

Debian cold boot takes 20–30s. Wait, retry. If still failing after 60s, open the VM in the Workstation GUI and check:

```bash
ip -br link          # nic0/nic1/nic2 — NOT ensXXX
systemctl status systemd-networkd
```

If interfaces still show as `ensXXX`, the `.link` MAC match failed — see [`docs/nexus-gateway.md`](nexus-gateway.md#nic-renaming-must-match-by-mac-not-pci-path).

### 4.2 `terraform apply` error: "Destination already exists"

A previous run left artifacts. Either:

```powershell
terraform destroy -auto-approve                                           # preferred
# or, if state is out of sync with reality:
Remove-Item -Recurse -Force H:\VMS\NexusPlatform\00-edge\nexus-gateway
```

### 4.3 `packer build` hangs on "Waiting for SSH"

Likely culprits:
- **Memory < 1 GB** → Debian installer drops into "Low memory mode" and stalls. `variables.pkr.hcl` pins `memory_mb = 1024` for this reason.
- **Preseed URL unreachable** → check that no Windows Firewall rule is blocking Packer's ephemeral HTTP server (port range declared in `boot_command`).
- **Wrong boot_wait** → bump `boot_wait` in `variables.pkr.hcl`.

Open the VNC endpoint printed in Packer's output (`vnc://127.0.0.1:59XX`) with TightVNC/RealVNC to see the live console.

### 4.4 VMware Workstation "This virtual machine appears to be in use"

A previous `vmrun` session didn't clean up the lock. Safe if you're sure nothing else has it open:

```powershell
Remove-Item H:\VMS\NexusPlatform\00-edge\nexus-gateway\*.lck -Recurse -Force
```

### 4.5 `git commit` fails with "hook failed"

Don't use `--no-verify`. Read the hook output, fix the underlying issue (usually a `terraform fmt` or trailing-whitespace miss), re-stage, re-commit.

---

## 5. Directory map

```
nexus-infra-vmware/
├── Makefile                    # top-level targets: make gateway, make gateway-apply, …
├── docs/
│   ├── architecture.md         # whole-fleet design
│   ├── licensing.md            # Windows licensing canon
│   ├── nexus-gateway.md        # per-VM runbook (Phase 0.B.1)
│   ├── deb13.md                # per-template runbook (Phase 0.B.2)
│   └── handbook.md             # this file
├── packer/
│   ├── _shared/                # Phase 0.B.3 step 2 — DRY Ansible roles shared across templates
│   │   └── ansible/roles/
│   │       ├── nexus_identity/        # owner pubkey, sshd hardening, host-key regen drop-in
│   │       ├── nexus_network/         # en*→nic0 + systemd-networkd + chrony client
│   │       ├── nexus_firewall/        # nftables baseline
│   │       └── nexus_observability/   # prometheus-node-exporter (room for OTel Collector)
│   ├── nexus-gateway/
│   │   ├── nexus-gateway.pkr.hcl
│   │   ├── http/preseed.cfg
│   │   ├── files/              # nftables.conf, dnsmasq.conf, chrony.conf
│   │   └── ansible/roles/nexus_gateway/
│   ├── deb13/
│   │   ├── deb13.pkr.hcl
│   │   ├── http/preseed.cfg
│   │   ├── files/              # nftables.conf, chrony.conf (client)
│   │   └── ansible/roles/debian_base/    # thin OS tail: apt pkgs + Debian-Security origin + MOTD
│   ├── ubuntu24/
│   │   ├── ubuntu24.pkr.hcl
│   │   ├── http/user-data + meta-data    # Subiquity autoinstall (NoCloud)
│   │   ├── files/              # nftables.conf, chrony.conf (ntp.ubuntu.com fallback)
│   │   └── ansible/roles/ubuntu_base/    # thin OS tail: apt pkgs + cloud-init/netplan scrub + Ubuntu origin + MOTD
│   └── ws2025-core/            # Phase 0.B.4 — Windows Server 2025 Core
│       ├── ws2025-core.pkr.hcl         # vmware-iso + WinRM + floppy Autounattend
│       ├── variables.pkr.hcl           # product_source evaluation|msdn + dual-ISO paths
│       ├── floppy/Autounattend.xml.tpl # rendered in-memory by templatefile()
│       ├── scripts/                    # PowerShell provisioners (parallel to Linux _shared roles)
│       │   ├── bootstrap-winrm.ps1          #   runs at OOBE FirstLogonCommand
│       │   ├── 00-install-vmware-tools.ps1
│       │   ├── 01-nexus-identity.ps1        #   nexusadmin + OpenSSH + admin-group authorized_keys
│       │   ├── 02-nexus-network.ps1         #   NIC rename nic0 + W32Time + DNS
│       │   ├── 03-nexus-firewall.ps1        #   default-deny + VMnet11 allowlist
│       │   ├── 04-nexus-observability.ps1   #   windows_exporter on :9182
│       │   ├── 05-windows-baseline.ps1      #   WU policy, telemetry, TLS, banner, pagefile
│       │   └── 99-sysprep.ps1               #   teardown build listener + generalize
│       └── files/nexusadmin-authorized_keys
├── scripts/
│   ├── configure-gateway-nics.ps1   # gateway-only (3 NICs, MAC-pinned)
│   ├── configure-vm-nic.ps1         # shared single-NIC rewriter (modules/vm uses this)
│   └── check-no-product-key.ps1
└── terraform/
    ├── gateway/                # Phase 0.B.1 — nexus-gateway
    ├── modules/vm/             # Phase 0.B.2 — reusable single-NIC clone driver
    ├── deb13-smoke/            # Phase 0.B.2 — smoke harness for modules/vm + deb13
    ├── ubuntu24-smoke/         # Phase 0.B.3 — smoke harness for ubuntu24
    └── ws2025-core-smoke/      # Phase 0.B.4 — smoke harness for ws2025-core
```

Template VMs live at `H:\VMS\NexusPlatform\_templates\<name>\<name>.vmx`.
Running instances at `H:\VMS\NexusPlatform\<tier>\<name>\<name>.vmx` (tier = `00-edge`, `10-core`, `20-apps`, …).

---

## 6. What's next

| Phase | Task | Doc |
|-------|------|-----|
| 0.B.1 | ✅ nexus-gateway | [nexus-gateway.md](nexus-gateway.md) |
| 0.B.2 | ✅ Debian 13 base template + reusable `modules/vm/` | [deb13.md](deb13.md) |
| 0.B.3 | ✅ Ubuntu 24.04 LTS base template + DRY `_shared/` roles (`nexus_identity`, `nexus_network`, `nexus_firewall`, `nexus_observability`) | [ubuntu24.md](ubuntu24.md) |
| 0.B.4 | ✅ Windows Server 2025 Core template (first Windows image; WinRM-build / OpenSSH-runtime; PowerShell provisioners parallel to the Linux shared roles) | [ws2025-core.md](ws2025-core.md) |
| 0.B.5 | Windows Server 2025 Desktop template | *(pending)* |
| 0.B.6 | Windows 11 Enterprise template | *(pending)* |
| 0.C   | Core services tier (`10-core/`) | *(pending)* |
| 0.D   | Vault + SSH key rotation | *(pending)* |

Keep this file in sync as phases land — each new VM gets a per-VM doc under `docs/` and a section added here under §1.
