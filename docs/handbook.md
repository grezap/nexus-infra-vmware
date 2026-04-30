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

# packer init + terraform init across the tree (pwsh-native -- no GNU make required)
foreach ($d in @(
    'packer\nexus-gateway','packer\deb13','packer\ubuntu24',
    'packer\ws2025-core','packer\ws2025-desktop','packer\win11ent','packer\vault'
)) { Push-Location $d; packer init .; Pop-Location }

foreach ($d in @(
    'terraform\gateway','terraform\deb13-smoke','terraform\ubuntu24-smoke',
    'terraform\ws2025-core-smoke','terraform\ws2025-desktop-smoke','terraform\win11ent-smoke',
    'terraform\envs\foundation','terraform\envs\security'
)) { Push-Location $d; terraform init; Pop-Location }
```

> The repo also ships a `Makefile` with equivalent `init` / `validate` / `<template>` targets for Linux/WSL/CI contexts, but **GNU make is not installed on the canonical Windows build host** -- the pwsh-native commands above (and the `scripts/<env>.ps1` wrappers introduced from §1c onward) are canonical for Windows operators per [`memory/feedback_build_host_pwsh_native.md`](../memory/feedback_build_host_pwsh_native.md).

### 0.4 SSH client setup on the build host (one-time)

Every Packer-built VM in this repo bakes the same owner pubkey into its `authorized_keys`:

- Linux: `packer/nexus-gateway/ansible/roles/nexus_gateway/files/nexusadmin.pub` (consumed by the gateway build) + the `_shared/ansible/roles/nexus_identity/` role for downstream Linux templates.
- Windows: `packer/_shared/powershell/files/nexusadmin-authorized_keys` (consumed by every Windows template via `_shared/powershell/scripts/01-nexus-identity.ps1`).

**Replace both files with your own pubkey** *before* building any template. Both files must contain the same `ssh-ed25519 …` line (the matching private key lives only on this host).

After templates are built and a gateway is deployed, configure the SSH client so subsequent `ssh nexusadmin@…` commands in this handbook (and in every `terraform apply` `next_step` output) Just Work without `-i` flags or passphrase prompts:

```powershell
# 1. Persistent ~/.ssh/config so `ssh nexusadmin@<lab-ip>` picks the right key automatically.
#
# The 192.168.70.1 stanza keeps default StrictHostKeyChecking (the gateway is
# pinned and its host keys only rotate when you rebuild it -- we want a real
# warning if they change unexpectedly).
#
# The 192.168.70.* stanza covers the volatile lab clones (foundation env,
# smoke harnesses, future role overlays). Their host keys regenerate on every
# clone-mini-OOBE (sysprep) and `terraform destroy + apply` cycle, which makes
# the default known_hosts behavior fight you. Disable strict checking and
# discard known_hosts state entirely for this range -- the trust boundary is
# VMnet11 itself (host-only, isolated).
@'
Host 192.168.70.1
    User nexusadmin
    IdentityFile ~/.ssh/nexus_gateway_ed25519

Host 192.168.70.*
    User nexusadmin
    IdentityFile ~/.ssh/nexus_gateway_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
'@ | Add-Content $HOME\.ssh\config

# 2. ssh-agent service: persistent, auto-starts at boot.
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service ssh-agent

# 3. Strip any passphrase from the key (one-off; the lab key is non-secret pre-Phase-0.D).
#    If `ssh-keygen -p` rejects the empty passphrase, type ""  (two double-quote chars) — known
#    Windows-OpenSSH-on-Win11 quirk where literal `""` got set as the passphrase during key gen.
ssh-keygen -p -f $HOME\.ssh\nexus_gateway_ed25519
# Old passphrase: <Enter>  (or  ""  +  <Enter>  if rejected)
# New passphrase: <Enter>
# Confirm:        <Enter>

# 4. Load the key into the agent (one prompt-free shot now, persists across reboots once config is in place).
ssh-add $HOME\.ssh\nexus_gateway_ed25519
ssh-add -l                      # must list nexus_gateway_ed25519 + the comment 'nexusadmin@nexus-gateway'

# 5. Verify zero-touch SSH against the gateway.
ssh nexusadmin@192.168.70.1 "echo ok"     # expect: ok
```

After this section, **every SSH command in this handbook (and in every `terraform apply` `next_step` output) is bare `ssh nexusadmin@<host>`** — no `-i`, no passphrase. If you skipped §0.4 (or are on a freshly imaged build host), prepend `-i $HOME\.ssh\nexus_gateway_ed25519` to any `ssh` invocation as the inline fallback.

**Windows remote shell quirk:** Win32-OpenSSH on the lab's Windows VMs defaults to `cmd.exe` as the remote shell. PowerShell-style commands (`Get-Service`, `Format-Table`, `;` separators, etc.) get mangled by cmd. Wrap them explicitly:

```powershell
ssh nexusadmin@<vm-ip> 'powershell -NoProfile -Command "hostname; (Get-Service sshd).Status"'
```

The `'…'` outer single quotes preserve the inner `"…"` for PowerShell's argument parsing.

---

## 1. Phase 0.B.1 — nexus-gateway (VM #0)

Full deep-dive: [`docs/nexus-gateway.md`](nexus-gateway.md).

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware"

# Build the template (~7 min)
Push-Location packer\nexus-gateway
packer build -var "output_directory=H:/VMS/NexusPlatform/_templates/nexus-gateway" nexus-gateway.pkr.hcl
Pop-Location

# Deploy the running instance (~7 sec)
Push-Location terraform\gateway; terraform apply -auto-approve; Pop-Location

# Sanity check
Test-NetConnection 192.168.70.1 -Port 53
Test-NetConnection 192.168.70.1 -Port 22
nslookup one.one.one.one 192.168.70.1

# Tear down (destroys instance, template survives)
Push-Location terraform\gateway; terraform destroy -auto-approve; Pop-Location
```

**If the destination path already exists** before the gateway template build, wipe it first so Packer doesn't conflate runs:

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
Push-Location packer\deb13; packer build .; Pop-Location
# Template lands at H:\VMS\NexusPlatform\_templates\deb13\deb13.vmx

# Smoke-test the template via terraform/modules/vm/ (~10 sec)
Push-Location terraform\deb13-smoke; terraform apply -auto-approve; Pop-Location
# Clone lands at H:\VMS\NexusPlatform\90-smoke\deb13-smoke\deb13-smoke.vmx
# It will DHCP from nexus-gateway in 192.168.70.200-.250.

# Find its lease + probe (assumes §0.4 SSH client setup; otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519`)
ssh nexusadmin@192.168.70.1 "grep '00:50:56:3f:00:20' /var/lib/misc/dnsmasq.leases"
200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }
Test-NetConnection <ip> -Port 22
Test-NetConnection <ip> -Port 9100
ssh nexusadmin@<ip>     # Linux remote shell defaults to bash — no wrapper needed

# Tear down
Push-Location terraform\deb13-smoke; terraform destroy -auto-approve; Pop-Location
```

### 1a.1 Rebuilding from scratch

```powershell
Push-Location terraform\deb13-smoke; terraform destroy -auto-approve; Pop-Location   # if a smoke VM exists
Remove-Item -Recurse -Force H:\VMS\NexusPlatform\_templates\deb13 -ErrorAction SilentlyContinue
Push-Location packer\deb13;          packer build .;                Pop-Location     # rebuild template
Push-Location terraform\deb13-smoke; terraform apply -auto-approve; Pop-Location     # verify
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
Push-Location packer\ws2025-core; packer build .; Pop-Location

# MSDN / retail path (owner only, requires bootstrap JSON with product key):
Push-Location packer\ws2025-core
packer build `
    -var "product_source=msdn" `
    -var "bootstrap_keys_file=$env:USERPROFILE/.nexus/secrets/windows-keys.json" .
Pop-Location

# Smoke-test
Push-Location terraform\ws2025-core-smoke; terraform apply -auto-approve; Pop-Location
# VM lands at H:/VMS/NexusPlatform/90-smoke/ws2025-core-smoke/*.vmx

# Find its lease + SSH in (assumes §0.4 SSH client setup; otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519`)
ssh nexusadmin@192.168.70.1 "awk '\$2==\"00:50:56:3f:00:22\" {print \$3}' /var/lib/misc/dnsmasq.leases"
Test-NetConnection <ip> -Port 22      # OpenSSH (key-only)
Test-NetConnection <ip> -Port 9182    # windows_exporter
# Wrap PowerShell commands in `'powershell -NoProfile -Command "..."'` -- Win32-OpenSSH default remote shell is cmd.exe.
ssh nexusadmin@<ip> 'powershell -NoProfile -Command "hostname; (Get-Service sshd, windows_exporter).Status"'

Push-Location terraform\ws2025-core-smoke; terraform destroy -auto-approve; Pop-Location
```

### 1b.1 The gotcha worth remembering (Windows template)

For admin users, Windows OpenSSH reads `C:\ProgramData\ssh\administrators_authorized_keys` — not `~/.ssh/authorized_keys`. If the pubkey is only in the user-profile file, sshd silently falls back to password auth (which 01-nexus-identity.ps1 has disabled) and every connection gets `Permission denied (publickey)`. The script writes to both paths and ACL-locks each. Full story in [`docs/ws2025-core.md`](ws2025-core.md#windowss-two-file-authorized_keys-quirk).

### 1b.2 Why PowerShell, not Ansible

The Linux shared roles (`nexus_identity`, `nexus_network`, `nexus_firewall`, `nexus_observability`) are systemd / nftables / chrony / node_exporter — every component is Linux-native. Windows has different primitives (Windows Firewall, W32Time, Windows Capabilities, windows_exporter MSI) and running Ansible against Windows requires either WSL + pywinrm on the build host or pulling Python into the template. Neither is worth the dependency weight for parity that's one-to-one with straight PowerShell. DRY extraction into `packer/_shared/powershell/` happens when `ws2025-desktop` (Phase 0.B.5) gives us a second concrete caller.

---

## 1c. Phase 0.C.1 — `envs/foundation` (always-on plumbing)

First Phase 0.C env. Lands the always-on support fleet that every other env (`data`, `ml`, `saas`, `microservices`, `demo-minimal`) depends on:

| VM                    | Template          | MAC                 | Tier path                                      | Role                                   |
|-----------------------|-------------------|---------------------|------------------------------------------------|----------------------------------------|
| `dc-nexus`            | `ws2025-desktop`  | `00:50:56:3F:00:25` | `H:/VMS/NexusPlatform/01-foundation/dc-nexus`        | Domain controller (AD DS promotion = role overlay, deferred) |
| `nexus-jumpbox` | `ws2025-desktop`  | `00:50:56:3F:00:26` | `H:/VMS/NexusPlatform/01-foundation/nexus-jumpbox` | Operator jump host (RSAT / GPMC / DNS tools) |

Both clones DHCP from `nexus-gateway` on VMnet11 (192.168.70.0/24, .200–.250 range).

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware"

# Pre-req: ws2025-desktop template must exist (Phase 0.B.5).
ls H:\VMS\NexusPlatform\_templates\ws2025-desktop\ws2025-desktop.vmx

# Deploy the env (clones + AD DS overlay + jumpbox join + 0.C.4 hardening)
pwsh -File scripts\foundation.ps1 apply

# Tear down (stops + deletes all foundation VMs)
pwsh -File scripts\foundation.ps1 destroy

# Full reproducibility cycle: destroy -> apply -> smoke (~17-18 min on
# the current build host; halts on first failure)
pwsh -File scripts\foundation.ps1 cycle

# Smoke-only (after apply already succeeded)
pwsh -File scripts\foundation.ps1 smoke
```

> The repo's `Makefile` ships equivalent targets (`foundation-apply`, `foundation-destroy`, `foundation-smoke`) for Linux/WSL/CI runners. The Windows build host has no GNU make -- prefer the `pwsh -File scripts\foundation.ps1 ...` wrapper above per [`memory/feedback_build_host_pwsh_native.md`](../memory/feedback_build_host_pwsh_native.md).

### 1c.1 Lease discovery + smoke probe

> All `ssh` commands in this section assume §0.4 SSH client setup is done (`~/.ssh/config` + `ssh-add`). Otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519` to each invocation.

Both VMs DHCP on first boot. Find leases via `nexus-gateway`'s dnsmasq:

```powershell
ssh nexusadmin@192.168.70.1 "grep -iE '00:50:56:3f:00:25|00:50:56:3f:00:26' /var/lib/misc/dnsmasq.leases"
```

Or scan VMnet11 from the Windows host:

```powershell
200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }
```

Probe each VM directly:

```powershell
Test-NetConnection <vm-ip> -Port 22      # OpenSSH (key-only)
Test-NetConnection <vm-ip> -Port 9182    # windows_exporter
# Win32-OpenSSH default remote shell is cmd.exe -- wrap PowerShell-style commands explicitly.
ssh nexusadmin@<vm-ip> 'powershell -NoProfile -Command "hostname; (Get-Service sshd).Status"'
```

Verify dc-nexus is ready for AD DS promotion (the role-overlay step lives in a later 0.C ticket — this stage just lands the bare clone):

```powershell
ssh nexusadmin@<dc-nexus-ip> 'powershell -NoProfile -Command "Get-WindowsFeature AD-Domain-Services, RSAT-AD-Tools, GPMC | Format-Table Name, InstallState"'
```

Verify nexus-jumpbox has the operator toolset:

```powershell
ssh nexusadmin@<jumpbox-ip> 'powershell -NoProfile -Command "Get-WindowsFeature RSAT-AD-Tools, RSAT-DNS-Server, RSAT-DHCP, GPMC | Format-Table Name, InstallState"'
```

### 1c.2 Why `envs/foundation/` and not just another `*-smoke/`

The per-template `*-smoke/` modules (Phase 0.B.2–0.B.6) each clone one template once to verify the template builds correctly. They are scratch — destroyed routinely as part of the Packer iteration loop.

`envs/foundation/` is the first **fleet env**: it composes multiple `modules/vm/` instances into a permanent always-on group. It's the shape the remaining 0.C envs (`data`, `ml`, `saas`, `microservices`, `demo-minimal`) will copy. Same `modules/vm/` driver underneath; the env is the composition layer above.

### 1c.3 MAC allocation (post-Phase-0.B)

| Slot | VM                    | Source                  |
|------|-----------------------|-------------------------|
| `:20`–`:24` | per-template smoke harnesses | `terraform/<template>-smoke/` |
| `:25` | `dc-nexus`            | `envs/foundation/`      |
| `:26` | `nexus-jumpbox` | `envs/foundation/`      |
| `:27`–`:2F` | unallocated          | next foundation slot is `:27` |

Subsequent envs will draw from the appropriate tier nibble (`:30-3F` data, `:40-4F` core, `:50-5F` apps) per the convention table in §1a.2.

### 1c.4 Constraints honored at this stage

- **Local `.tfstate`** — `envs/foundation/` writes state under its own dir. Migration to a Consul KV backend is Phase 0.E.
- **Bootstrap creds** — both clones inherit `nexusadmin` / `NexusPackerBuild!1` from the Packer template; post-clone rotation lives in Phase 0.D when Vault lands.
- **AD DS DSRM password** (Phase 0.C.2) — `var.dsrm_password` defaults to `NexusDSRM!1` in `variables.tf`. Same Vault-rotation horizon (Phase 0.D).

### 1c.5 Smoke-time gotcha — pre-`dc5c588` Windows templates

**Symptom:** `ssh nexusadmin@<clone-ip>` (or `ssh -i $HOME\.ssh\nexus_gateway_ed25519 …` if you skipped §0.4) returns `Connection reset by <ip> port 22` immediately after host-key acceptance. `Test-NetConnection -Port 22` succeeds (sshd is listening), the host key exchange completes, but every userauth attempt resets the connection.

**Root cause:** Lesson #8 from 0.B.6 dropped `Match Group administrators` + `KerberosAuthentication`/`GSSAPIAuthentication`/`ChallengeResponseAuthentication` from `_shared/powershell/scripts/01-nexus-identity.ps1` because they crash sshd-children on userauth-request reprocess. The cleanup is only baked into a template at Packer build time. Any Windows template last built **before commit `dc5c588`** (where the cleanup landed) still ships the old `sshd_config` and reproduces the bug — even though lesson #8's narrative said Server SKUs were unaffected. The clone's event log will show `sshd: rexec line N: Unsupported option KerberosAuthentication` per failed connection.

**Affected templates (as of 2026-04-28):**

| Template | Last build | Status |
|---|---|---|
| `nexus-gateway` | `b56aa7b` (Linux, unaffected) | clean |
| `deb13` / `ubuntu24` | (Linux, unaffected) | clean |
| `ws2025-core` | `42a5205` | **pre-`dc5c588` — needs rebuild before next use** |
| `ws2025-desktop` | `68012e8` | **pre-`dc5c588` — rebuild required for foundation env** |
| `win11ent` | `5729472`+ (rebuilt as part of `dc5c588`) | clean |

**Hot-fix on a running clone (~30 seconds; per-clone, doesn't fix the template):**

Open the VM in Workstation GUI (`File → Open → H:\VMS\NexusPlatform\01-foundation\<vm>\<vm>.vmx`), login as `nexusadmin` (build-time password from `packer/ws2025-desktop/variables.pkr.hcl`), launch elevated PowerShell, then:

```powershell
Copy-Item 'C:\ProgramData\ssh\sshd_config' 'C:\ProgramData\ssh\sshd_config.bak' -Force
$config = @'
# sshd_config -- NexusPlatform Windows baseline (hot-fix matching _shared/powershell/scripts/01-nexus-identity.ps1)
Port 22
AddressFamily inet
ListenAddress 0.0.0.0

PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
PermitEmptyPasswords no

AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys

ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30

AllowUsers nexusadmin

Subsystem sftp sftp-server.exe
'@
Set-Content -Path 'C:\ProgramData\ssh\sshd_config' -Value $config -Encoding ascii
& 'C:\Windows\System32\OpenSSH\sshd.exe' -t   # must print nothing
Restart-Service sshd -Force
```

Then verify from the Windows host (Win32-OpenSSH defaults its remote shell to `cmd.exe`, so wrap PowerShell-style commands explicitly):

```powershell
ssh nexusadmin@<clone-ip> 'powershell -NoProfile -Command "hostname; whoami; (Get-Service sshd).Status"'
```

**Permanent fix — rebuild affected templates against current `_shared/powershell/`:**

```powershell
# Rebuild ws2025-desktop (foundation env consumer; ~25-40 min depending on host)
Remove-Item -Recurse -Force H:\VMS\NexusPlatform\_templates\ws2025-desktop -ErrorAction SilentlyContinue
cd packer\ws2025-desktop
packer build .

# Tear down + redeploy foundation against the new template
cd ..\..\terraform\envs\foundation
terraform destroy -auto-approve
terraform apply -auto-approve

# Re-smoke (should now succeed zero-touch, no hot-fix needed)
ssh nexusadmin@<dc-nexus-ip> 'powershell -NoProfile -Command "hostname"'
ssh nexusadmin@<jumpbox-ip>  'powershell -NoProfile -Command "hostname"'
```

**Forward implication for `_shared/` discipline:** any change to `packer/_shared/powershell/scripts/*.ps1` creates an "obsolete template" footprint. Every Windows template that consumes the modified script needs a rebuild before its clones can be relied on. Consider this when the next shared-script edit lands — flag affected templates in the commit message and rebuild them in the same effort.

---

## 1d. Phase 0.C.2 — AD DS role overlay on `dc-nexus`

Layered on top of 0.C.1's bare-clone foundation. Promotes the `dc-nexus` ws2025-desktop clone into a real domain controller for `nexus.lab` and adds an env-scoped DNS forward on `nexus-gateway` so VMnet11 hosts can resolve domain queries.

**Files (all under `terraform/envs/foundation/`):**

| File | Purpose |
|---|---|
| `role-overlay-dc-nexus.tf` | 5 sequential `null_resource`s: rename → wait_renamed → promote → wait_promoted → verify. Top-level (not nested in `module.dc_nexus`) so each step is independently `-target`-able. |
| `role-overlay-gateway-dns.tf` | Single `null_resource` that writes `/etc/dnsmasq.d/foundation-nexus-lab.conf` on the gateway + reloads dnsmasq. Idempotent + has a destroy-time provisioner that cleanly removes the conf. |
| `variables.tf` (extended) | `enable_dc_promotion`, `enable_gateway_dns_forward`, `ad_domain`, `ad_netbios`, `dsrm_password`, `dc_promotion_timeout_minutes`. |

**Selective ops** (per [`memory/feedback_selective_provisioning.md`](https://github.com/grezap/nexus-infra-vmware) — every piece is independently controllable):

```powershell
cd terraform\envs\foundation

# Default: clones + AD DS overlay + DNS forward (the always-on plumbing posture)
terraform apply -auto-approve

# Bare clones only -- skip the multi-minute promotion, useful when iterating
# on the VM clone path or testing module/vm changes.
terraform apply -var enable_dc_promotion=false -auto-approve

# Just dc-nexus, no jumpbox (saves ~1.5 GB RAM during single-VM iteration)
terraform apply -target=module.dc_nexus -auto-approve

# Iterate on the promotion step without re-cloning the VM
terraform apply -target=null_resource.dc_nexus_promote -auto-approve

# Re-run a specific overlay step after fixing something
terraform taint null_resource.dc_nexus_promote
terraform apply -target=null_resource.dc_nexus_promote -auto-approve

# Tear down just the role overlay (keeps bare clones running)
terraform apply -var enable_dc_promotion=false -var enable_gateway_dns_forward=false -auto-approve
```

**Smoke gate:**

```powershell
# DC's own view of the forest
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADDomain | Format-List Forest, DomainMode, NetBIOSName"'

# Jumpbox (or any VMnet11 client) can locate the DC via DNS SRV
ssh nexusadmin@192.168.70.241 'powershell -NoProfile -Command "nltest /dsgetdc:nexus.lab"'

# Gateway forwards nexus.lab queries to dc-nexus
ssh nexusadmin@192.168.70.1 "dig @127.0.0.1 _ldap._tcp.nexus.lab SRV +short"
# Expect lines like: 0 100 389 dc-nexus.nexus.lab.
```

### 1d.1 Timing expectations

| Step | Wall-clock |
|---|---|
| `module.dc_nexus` + `module.nexus_admin_jumpbox` (bare clones) | 15-30 sec |
| `null_resource.dc_nexus_rename` (Rename-Computer + reboot trigger) | 5 sec |
| `null_resource.dc_nexus_wait_renamed` (poll until hostname == `dc-nexus`) | 60-180 sec |
| `null_resource.dc_nexus_promote` (`Install-ADDSForest`, kicks reboot) | 2-5 min |
| `null_resource.dc_nexus_wait_promoted` (poll until `Get-ADDomain.Forest` matches) | 3-6 min after the promotion reboot |
| `null_resource.dc_nexus_verify` | 2-3 sec |
| `null_resource.gateway_dns_forward` | 2-3 sec |
| **Total cold path** | **~8-15 min** |

`var.dc_promotion_timeout_minutes` defaults to 15 per step; bump it if the build host is slow.

### 1d.2 Idempotency

Each overlay step is idempotent on re-apply:

- **Rename** — checks `hostname` first; no-op if already `dc-nexus`.
- **Promote** — checks `(Get-ADDomain).Forest` first; no-op if `nexus.lab` already exists.
- **DNS forward** — looks for the marker comment in `/etc/dnsmasq.d/foundation-nexus-lab.conf`; no-op if present.

Bumping the `*_v` field in any `triggers` block forces re-execution (use this when iterating on the script content, since terraform can't detect heredoc string changes).

### 1d.3 NOT in scope for 0.C.2

- **Adding the jumpbox to the domain** — moved to Phase 0.C.3 (§1e below). `Add-Computer -DomainName nexus.lab` runs as a separate overlay so 0.C.2 can land/test in isolation.
- **OUs / GPOs / service accounts** — start trivial in this phase; lab DC promotion only.
- **Second DC for replication** — Phase 0.G (or whenever HA is needed).
- **Vault-backed DSRM password** — Phase 0.D.

### 1d.4 Post-promotion remediation (baked into the `v4` promote step)

`Install-ADDSForest` performs a hostile takeover of the local SAM. Without remediation in the same automation block, the promoted DC is unreachable via SSH and `nexusadmin` can't authenticate. The `v4` promote step runs all four of these AFTER `Install-ADDSForest -NoRebootOnCompletion` returns and BEFORE the reboot:

| Step | Why |
|---|---|
| `Set-LocalUser Administrator -Password ...; Enable-LocalUser` (BEFORE promotion) | `Install-ADDSForest`'s prereq check fails with `the local Administrator password is blank` because sysprep `/generalize` wipes the unattend-provided password on every clone. The local Administrator becomes the domain Administrator on forest creation, so its password must be set first. |
| `Set-ADAccountPassword -Identity nexusadmin -Reset` | AD DS migrates the local `nexusadmin` user into the AD database but blanks its password. Without this reset, `nexusadmin` is locked out of the new DC. |
| `Add-ADGroupMember 'Domain Admins' -Members nexusadmin` | Migrated users land in `Domain Users` only, never Domain Admins. Without admin rights, `nexusadmin` can't manage the DC even if their password is reset. |
| `sshd_config: comment out AllowUsers; Restart-Service sshd` | Win32-OpenSSH receives the post-promotion username as `nexus\nexusadmin` (domain-prefixed), which doesn't match the bare-username `AllowUsers nexusadmin` directive. SSH rejects every connection with "User ... not allowed because not listed in AllowUsers" (visible in `OpenSSH/Operational` event log Id 4). On a DC, dropping the directive entirely is the cleanest fix — trust = pubkey + Administrators group is sufficient. |

Memory: [`feedback_addsforest_post_promotion.md`](memory/feedback_addsforest_post_promotion.md) canonizes this pattern for any future AD DS automation, not just NexusPlatform.

### 1d.5 dnsmasq cache lesson — restart, don't reload

The `gateway_dns_forward` resource (`dns_overlay_v=2`) calls `systemctl restart dnsmasq` rather than `systemctl reload`. Discovered 2026-04-29:

- `systemctl reload dnsmasq` sends SIGHUP, which re-reads `/etc/dnsmasq.d/` files (so the new `server=/nexus.lab/192.168.70.240` rule loaded) BUT does NOT flush the DNS cache.
- If `nexus.lab` queries hit dnsmasq BEFORE the forward zone was added, the response chain went to the public upstreams (1.1.1.1, 1.0.0.1, 9.9.9.9) which returned a DNSSEC-signed NXDOMAIN. dnsmasq cached that NXDOMAIN.
- After the SIGHUP reload, the cached NXDOMAIN kept being served until the cache TTL expired — the new forward rule was loaded but never consulted.
- `systemctl restart dnsmasq` drops the entire cache as part of process restart, so the forward is live immediately.

If you ever need to add a forward zone to dnsmasq under load (where a service restart is undesirable), an alternative is to also clear the cache without a full restart: `kill -USR1 $(pidof dnsmasq)` dumps cache stats, but there's no signal to flush. The closest is `dnsmasq -k -c 0` (cache-size=0) at startup. For our purposes, restart is the simpler and more reliable path.

### 1d.6 Smoke gate from workgroup peers — don't trust `nltest /dsgetdc:`

`nltest /dsgetdc:nexus.lab` from a non-domain-joined peer (e.g. the `nexus-jumpbox` in its current workgroup state) returns `1355 ERROR_NO_SUCH_DOMAIN` even when the DC is fully functional. Reason: Netlogon service is dormant on workgroup machines; tools that depend on it can't auto-start it without a domain context. **Don't use nltest from workgroup peers as a smoke gate.** Use these instead:

```powershell
# 1. nltest from the DC ITSELF -- decisive proof of forest health
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "nltest /dsgetdc:nexus.lab"'

# 2. Resolve-DnsName from the peer -- proves DNS chain (peer -> gateway -> DC)
ssh nexusadmin@192.168.70.241 'powershell -NoProfile -Command "Resolve-DnsName _ldap._tcp.nexus.lab -Type SRV"'

# 3. TCP probes to the DC's AD ports from the peer -- proves connectivity
ssh nexusadmin@192.168.70.241 'powershell -NoProfile -Command "Test-NetConnection 192.168.70.240 -Port 389; Test-NetConnection 192.168.70.240 -Port 88; Test-NetConnection 192.168.70.240 -Port 135"'

# 4. Forest verify from the DC's own AD module
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADDomain | Format-List Forest, DomainMode, NetBIOSName"'
```

Once `nexus-jumpbox` is domain-joined (Phase 0.C.3), Netlogon auto-starts and stays running, after which `nltest /dsgetdc:nexus.lab` from the jumpbox works cleanly.

---

## 1e. Phase 0.C.3 — `nexus-jumpbox` domain-join to `nexus.lab`

Layered on top of 0.C.2's promoted DC. Joins `nexus-jumpbox` to the `nexus.lab` domain so it becomes a real domain member: operators authenticate as `nexus\nexusadmin` (or any future domain user), Group Policy can target it, RSAT tools work without explicit `-Credential`, and the cosmetic `nltest 1355` from §1d.6 disappears (Netlogon auto-starts post-join).

**File:** `terraform/envs/foundation/role-overlay-jumpbox-domainjoin.tf` — 3 sequential top-level `null_resource`s:

| Step | What it does |
|---|---|
| `jumpbox_domain_join` | Single base64-encoded SSH command that (a) patches sshd_config to drop `AllowUsers nexusadmin` so post-join SSH as `nexus\nexusadmin` works, then (b) `Add-Computer -DomainName nexus.lab -NewName nexus-jumpbox -Credential <NEXUS\nexusadmin> -Force -Restart`. Add-Computer renames the local hostname AND adds to the domain in one atomic call. |
| `jumpbox_wait_rejoined` | Polls `(Get-WmiObject Win32_ComputerSystem).PartOfDomain` over SSH until True + Domain=nexus.lab. ~3-7 min wall-clock. |
| `jumpbox_verify` | Emits `Win32_ComputerSystem` membership state, `nltest /dsgetdc:nexus.lab` (now succeeds — Netlogon is live), and `Get-ADComputer nexus-jumpbox` (proves the box is registered in AD). |

**Toggle:** `var.enable_jumpbox_domain_join` (bool, default `true`). Implicitly depends on `enable_dc_promotion=true` because it `depends_on null_resource.dc_nexus_verify`.

**Selective ops:**

```powershell
cd terraform\envs\foundation

# Default — runs DC overlay + jumpbox join (~10-20 min cold including dc promotion + reboots)
terraform apply -auto-approve

# Skip just the join — keeps DC + bare workgroup jumpbox
terraform apply -var enable_jumpbox_domain_join=false -auto-approve

# Iterate on the join step alone (after DC is up)
terraform apply -target=null_resource.jumpbox_domain_join -auto-approve

# Re-fire just the join (script changed, want to re-run)
terraform taint null_resource.jumpbox_domain_join
terraform apply -target=null_resource.jumpbox_domain_join -auto-approve
```

**Smoke gate:**

```powershell
# Jumpbox is a real domain member
ssh nexusadmin@192.168.70.241 'powershell -NoProfile -Command "(Get-WmiObject Win32_ComputerSystem) | Format-List Name, Domain, PartOfDomain, DomainRole"'
# Expect: Domain = nexus.lab, PartOfDomain = True, DomainRole = 3 (member workstation)

# Netlogon is live (nltest works from the jumpbox now)
ssh nexusadmin@192.168.70.241 'powershell -NoProfile -Command "nltest /dsgetdc:nexus.lab"'

# Jumpbox is registered in AD
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADComputer nexus-jumpbox | Format-List Name, DNSHostName, DistinguishedName"'
```

**Idempotency:** the join script's first action over SSH is an idempotency check — `(Get-WmiObject).PartOfDomain` + `Domain == nexus.lab`. If both true, the script exits 0 and Add-Computer is never called. Re-applies are safe.

### 1e.1 NOT in scope for 0.C.3

- **OUs for organizing the jumpbox + future domain members** — Phase 0.C.4+
- **GPO for jumpbox lockdown** — Phase 0.C.4+
- **Removing the local `nexusadmin` from the jumpbox** — left in place as fallback during early lab phases; cleaned up when Phase 0.D rotates credentials via Vault
- **Joining `dc-nexus` to itself** (it's the DC; it's *the* domain authority by definition; no `Add-Computer` needed)

### 1e.2 Carries forward the post-AD lessons from §1d.4

The same `sshd_config AllowUsers` trap that bit us on dc-nexus also applies to any domain-joined Windows peer. The join overlay applies the same patch (drop the directive, restart sshd) BEFORE the Add-Computer reboot so the post-reboot sshd allows domain-format usernames immediately. Memory entry [`feedback_addsforest_post_promotion.md`](memory/feedback_addsforest_post_promotion.md) covers both DC and member-server cases — same trust model (pubkey + Administrators group), same fix.

### 1e.3 The five Windows-over-SSH structural rules (canonical post-mortem)

Phase 0.C.3 took five iterations of `domainjoin_v` and four of `rename_overlay_v` to land. Each iteration peeled off a different class of silent failure. The lessons are worth canonizing for any future Terraform overlay that drives Windows VMs through SSH — they apply to data/ml/saas envs and beyond, not just AD DS. Full canonical version in [`memory/feedback_windows_ssh_automation.md`](memory/feedback_windows_ssh_automation.md); summary:

1. **Hostnames must be ≤15 chars (NetBIOS limit).** `Add-Computer -NewName` and `Rename-Computer -NewName` silently reject longer names. Lab phase 0.C.3 v2 used `nexus-admin-jumpbox` (19 chars); v3 shortened to `nexus-jumpbox` (13).

2. **Base64-encode every multi-token PowerShell SSH command.** `ssh user@host "powershell -Command \"...\""` looks fine but the cmd.exe in between mangles the inner quoting. PARTIAL execution — first cmdlet runs, rest silently disappears. Use `powershell -EncodedCommand <b64>` (UTF-16-LE base64). Bit promote_v=1 (`Install-WindowsFeature` ran but `Install-ADDSForest` didn't) and rename_overlay_v=1 (`Rename-Computer` never queued).

3. **SSH readiness ≠ TCP port 22 open.** `Test-NetConnection -Port 22` returns True before sshd is fully ready. Use a real ssh echo probe: `ssh -o BatchMode=yes -o ConnectTimeout=5 user@host "echo ok"` until it returns `ok`. Rename_overlay_v=3 trusted Test-NetConnection; v4 switched to echo probe.

4. **Retry the actual operation 3-5 times.** Even after the echo probe succeeds, sshd-session.exe spawns can race during early boot. Wrap the real SSH call in a retry loop and treat `Connection (timed out|refused)` in stderr as retryable. Distinguish from exit 255 produced by `Restart-Computer -Force` dropping the connection mid-command (that's success). Capture `2>&1 | Out-String` so terraform's stderr suppression doesn't hide the signal.

5. **Don't restart the service hosting your running script.** `Restart-Service sshd -Force` inside an SSH session kills that session — the rest of the script never runs. If you need to apply a sshd_config change, write the file but DON'T restart sshd inline; the next reboot (e.g. `Add-Computer -Restart`) will reload it cleanly. Bit domainjoin_v=1.

If you're writing a new overlay that touches Windows over SSH, bake all five in from line 1 of the script. They're cheap to implement and silent failures are expensive to diagnose (Phase 0.C.3 took ~6 hours of iteration to learn them all).

---

## 1f. Phase 0.C.4 — AD DS hardening on `dc-nexus`

Layered on top of 0.C.3's promoted DC + domain-joined jumpbox. Adds the always-on plumbing that makes `nexus.lab` a real, manageable forest rather than just a promoted DC + computer objects sitting in the default Containers. Four independent overlays, each with its own `enable_dc_*` toggle (default `true`) and its own role-overlay file under `terraform/envs/foundation/`.

**Files (all under `terraform/envs/foundation/`):**

| File | Purpose | Toggle |
|---|---|---|
| `role-overlay-dc-ous.tf` | Create OU=Servers, OU=Workstations, OU=ServiceAccounts, OU=Groups under DC=nexus,DC=lab + move `nexus-jumpbox` from CN=Computers into OU=Servers. dc-nexus stays at the built-in CN=Domain Controllers (Microsoft hard rule). | `enable_dc_ous` |
| `role-overlay-dc-password-policy.tf` | Default Domain Password + Lockout Policy via `Set-ADDefaultDomainPasswordPolicy`. NIST SP 800-63B-aligned defaults. | `enable_dc_password_policy` |
| `role-overlay-dc-reverse-dns.tf` | AD-integrated reverse DNS zone `70.168.192.in-addr.arpa.` (VMnet11 only — `192.168.70.0/24`) + PTR records for dc-nexus (.240) and nexus-jumpbox (.241). | `enable_dc_reverse_dns` |
| `role-overlay-dc-time.tf` | Configure dc-nexus (PDC) as authoritative time source via `w32tm /config /reliable:YES`; sync from public NTP peers. | `enable_dc_time_authoritative` |

All four `depends_on null_resource.dc_nexus_verify` (and `dc_ous` also depends on `null_resource.jumpbox_verify` for the jumpbox-move phase). When `enable_dc_promotion=false`, all four are no-ops.

**Selective ops** (per [`memory/feedback_selective_provisioning.md`](https://github.com/grezap/nexus-infra-vmware) — every hardening overlay independently controllable):

```powershell
cd terraform\envs\foundation

# Default — everything (AD DS overlay + jumpbox join + 4 hardening overlays)
terraform apply -auto-approve

# Skip a single overlay
terraform apply -var enable_dc_ous=false -auto-approve
terraform apply -var enable_dc_password_policy=false -auto-approve
terraform apply -var enable_dc_reverse_dns=false -auto-approve
terraform apply -var enable_dc_time_authoritative=false -auto-approve

# Skip ALL 0.C.4 hardening — keep DC + jumpbox + domain-join only
terraform apply -var enable_dc_ous=false -var enable_dc_password_policy=false `
                -var enable_dc_reverse_dns=false -var enable_dc_time_authoritative=false `
                -auto-approve

# Iterate on a single overlay (e.g. tune password policy values)
terraform taint null_resource.dc_password_policy
terraform apply -target=null_resource.dc_password_policy -auto-approve

# Tune a specific value (overrides the default)
terraform apply -var dc_password_min_length=14 -auto-approve
```

**Smoke gate:** the canonical end-to-end check on Windows is `pwsh -File scripts\foundation.ps1 smoke` (which delegates to `scripts\smoke-0.C.4.ps1`). It runs 28 checks + summarizes pass/fail with a non-zero exit on any failure -- wire it into CI or run it manually after every apply. The Makefile equivalent (`foundation-smoke` target) is provided for Linux/WSL/CI only; pwsh is canonical on the Windows build host per [`memory/feedback_build_host_pwsh_native.md`](../memory/feedback_build_host_pwsh_native.md). The individual commands below are useful for ad-hoc debugging when a check fails:

```powershell
# OU layout + jumpbox move
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADOrganizationalUnit -Filter * | Format-Table Name, DistinguishedName -AutoSize"'
# Expect: Servers, Workstations, ServiceAccounts, Groups (plus the built-in Domain Controllers)
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADComputer nexus-jumpbox | Format-List Name, DistinguishedName"'
# Expect: DistinguishedName = CN=NEXUS-JUMPBOX,OU=Servers,DC=nexus,DC=lab

# Default Domain Password Policy
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADDefaultDomainPasswordPolicy | Format-List MinPasswordLength, LockoutThreshold, LockoutDuration, MaxPasswordAge, ComplexityEnabled"'
# Expect: MinPasswordLength=12, LockoutThreshold=5, LockoutDuration=00:15:00, MaxPasswordAge=00:00:00 (= never), ComplexityEnabled=True

# Reverse DNS zone + PTR records
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-DnsServerZone -Name 70.168.192.in-addr.arpa | Format-List ZoneName, ZoneType, IsDsIntegrated"'
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-DnsServerResourceRecord -ZoneName 70.168.192.in-addr.arpa -RRType Ptr | Format-Table HostName, RecordData -AutoSize"'
# Expect: PTRs at 240 (dc-nexus.nexus.lab.) and 241 (nexus-jumpbox.nexus.lab.)
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Resolve-DnsName -Name 192.168.70.241 -Server 192.168.70.240"'
# Expect: nexus-jumpbox.nexus.lab.

# W32Time PDC config
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "w32tm /query /configuration | Select-String NtpServer"'
# Expect: NtpServer: time.cloudflare.com,0x8 time.nist.gov,0x8 pool.ntp.org,0x8 time.windows.com,0x8
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "w32tm /query /status"'
# Expect: Source = one of the configured peers (not Local CMOS Clock); Stratum < 16
```

**Build-host reachability invariant** (per [`memory/feedback_lab_host_reachability.md`](memory/feedback_lab_host_reachability.md)) — verify after every hardening apply:

```powershell
# SSH/22 + RDP/3389 from the build host to every fleet VM must remain reachable
Test-NetConnection 192.168.70.240 -Port 22    # dc-nexus SSH
Test-NetConnection 192.168.70.240 -Port 3389  # dc-nexus RDP
Test-NetConnection 192.168.70.241 -Port 22    # jumpbox SSH
Test-NetConnection 192.168.70.241 -Port 3389  # jumpbox RDP
```

A `False` on any of these is a critical regression — every fleet VM stays manageable from the build host (Greg has no out-of-band path).

### 1f.1 Timing expectations

| Overlay | Wall-clock |
|---|---|
| `null_resource.dc_ous` (4 OUs + jumpbox move) | 5-10 sec |
| `null_resource.dc_password_policy` (Set-ADDefaultDomainPasswordPolicy + verify) | 3-5 sec |
| `null_resource.dc_reverse_dns` (Add-DnsServerPrimaryZone + 2 PTRs) | 3-5 sec |
| `null_resource.dc_time_authoritative` (w32tm /config + restart + resync) | 8-12 sec (the `/resync /force` waits for an NTP round-trip) |
| **Total 0.C.4 hardening incremental cost** | **~30-60 sec** added to the foundation env apply |

The four overlays could in principle run in parallel (they have no inter-dependencies beyond `dc_nexus_verify`), but Terraform's default graph parallelism handles that automatically — no special config needed.

### 1f.2 Idempotency

Every overlay's first action is a state probe; only mutate if state differs from desired:

| Overlay | Probe | Mutation guard |
|---|---|---|
| `dc_ous` | `Get-ADOrganizationalUnit -Identity ...` (per OU); `Get-ADComputer nexus-jumpbox` for the move | Skip OU if already present; skip move if jumpbox is already in `OU=Servers` (or absent entirely when `enable_jumpbox_domain_join=false`) |
| `dc_password_policy` | `Get-ADDefaultDomainPasswordPolicy` | Skip if all 8 fields match desired values; otherwise `Set-` once and verify |
| `dc_reverse_dns` | `Get-DnsServerZone`, `Get-DnsServerResourceRecord` | Skip zone create if present; skip each PTR if present |
| `dc_time_authoritative` | `w32tm /query /configuration` parsed for `NtpServer` and `Type` | Skip reconfigure if both match desired; otherwise apply once |

`terraform apply` is safe to re-run mid-lab; bumping the `*_overlay_v` field in any `triggers` block forces re-execution (use this when iterating on the script content).

### 1f.3 NOT in scope for 0.C.4

- **Second DC for replication HA** → Phase 0.C.5 or its own phase (Phase 0.G in original architecture roadmap). Substantial scope (FSMO transfer test, Sysvol replication via DFSR, separate IP/MAC, /etc/hosts on gateway, etc.).
- **Service accounts** (`svc-postgres`, `svc-mongo`, etc.) → Phase 0.C.6+ when those services exist.
- **GMSA / managed service accounts** → Phase 0.D (requires Vault for rotation policy).
- **Login banner GPO** → cosmetic; fold in later when there are more GPOs to manage.
- **`OU=Users`** → premature; no human users beyond `nexusadmin` yet.
- **GPOs beyond what the Default Domain Policy provides** (CIS hardening baselines, AppLocker, Defender ASR, Windows Firewall lockdown) → Phase 0.C.5+. The build-host reachability invariant ([`memory/feedback_lab_host_reachability.md`](memory/feedback_lab_host_reachability.md)) constrains all future GPO baselines: any baseline that restricts inbound TCP/22 or TCP/3389 must default-allow `10.0.70.0/24` (the build-host LAN).
- **Tightening `MinPasswordLength` to 14** → Phase 0.D once Vault generates compliant creds. Setting it earlier strands the existing 12-char bootstrap creds at the next rotation.
- **VMnet10 reverse DNS** (`70.0.10.in-addr.arpa.`) → not AD-relevant; the build-host LAN doesn't need PTRs from dc-nexus.
- **Pivoting time sync to gateway-as-NTP-server** → separate ticket post-0.C.4. Requires verifying nexus-gateway's chrony exposes server mode (it currently runs in client posture per `_shared/ansible/roles/nexus_network`).

### 1f.4 Why this layered shape (and not one big hardening overlay)

Each concern is one file with one toggle, so a future iteration on (e.g.) the password policy doesn't force a re-apply of OU layout, reverse DNS, and time config. Per [`memory/feedback_selective_provisioning.md`](memory/feedback_selective_provisioning.md), bundled-only operations are a design defect — and "AD hardening" is exactly the kind of bundle that grows without bound (CIS baselines, Defender ASR, AppLocker, audit policy, Kerberos armoring, …). Establishing the one-concern-per-overlay shape now sets the canonical pattern for Phase 0.C.5+ and beyond.

The four overlays also each pay the canonical SSH transit cost (echo probe + base64 + retry, per `feedback_windows_ssh_automation.md`). The redundancy is worth it: an iteration loop that taints just one overlay never has to re-run the others, and the SSH probes within each overlay are short (~5-15 sec vs the multi-minute promotion).

### 1f.5 AD-cmdlet run point — always from the DC, never from the jumpbox

Per the last entry in [`memory/feedback_addsforest_post_promotion.md`](memory/feedback_addsforest_post_promotion.md): SSH to a domain member runs as the **local** SAM `nexusadmin`, which has no AD-authenticated context — `Get-ADOrganizationalUnit`, `Get-ADComputer`, `Set-ADDefaultDomainPasswordPolicy`, etc. would fail "Unable to contact the server" even when ADWS is healthy on the DC. All four overlays SSH directly to the DC (`192.168.70.240`); the jumpbox isn't a participant in the hardening flow. (The jumpbox's role is post-deployment operator UX — RSAT MMC consoles, GPMC — not automation transit.)

---

## 1g. Phase 0.D.1 — `envs/security` (3-node Vault Raft cluster)

First step of Phase 0.D — bootstraps a 3-node Vault Raft cluster on the foundation tier. Concrete services (data env, ml env, etc.) past this point can read credentials from Vault instead of plaintext Terraform vars; AD-DS bootstrap creds (DSRM, local Administrator, nexusadmin) migrate into Vault KV at 0.D.4.

**Canon mapping** (per [`memory/feedback_master_plan_authority.md`](memory/feedback_master_plan_authority.md) — every implementation choice cites canonical source):

| Choice | Source |
|---|---|
| 3-node Vault Raft cluster | `MASTER-PLAN.md` Phase 0.D (line 145) |
| Hostnames `vault-1`, `vault-2`, `vault-3` | `nexus-platform-plan/docs/infra/vms.yaml` lines 55-57 |
| OS = Debian 13 | `vms.yaml` lines 55-57 |
| 2 vCPU per node | `vms.yaml` lines 55-57 |
| 40 GB disk per node | `vms.yaml` lines 55-57 |
| Tier directory `01-foundation/vault-N` | `vms.yaml` lines 55-57 |
| VMnet11 IPs `.121/.122/.123` | `vms.yaml` lines 55-57 |
| VMnet10 IPs `192.168.10.121/.122/.123` | `vms.yaml` lines 55-57 |
| Dual-NIC (VMnet10 backplane + VMnet11 service) | `MASTER-PLAN.md` line 188 |
| AppRole + KV-v2 at `nexus/*` | `MASTER-PLAN.md` Phase 0.D (line 145) |
| MAC tier `:40-4F` (core services) | handbook §1a |
| **Approved deviation: 2 GB RAM** (canon says 4 GB) | user-approved 2026-04-29 per [`memory/feedback_prefer_less_memory.md`](memory/feedback_prefer_less_memory.md); will update vms.yaml to match observed-sufficient sizing |
| **Org choice: `envs/security/`** (canon-silent) | user-approved 2026-04-29 — canon specifies tier directory but not env name; security keeps Vault iteration isolated from foundation env's AD plumbing |

**Files:**

| Path | Purpose |
|---|---|
| `packer/vault/` | Packer template — Debian 13 + Vault binary (`var.vault_version`, default 1.18.4) + systemd units + `vault-firstboot.sh` (per-clone NIC config + TLS cert + render `vault.hcl`) |
| `terraform/envs/security/main.tf` | Three `module "vault_N"` blocks (dual-NIC) |
| `terraform/envs/security/role-overlay-vault-cluster.tf` | 4 sequential null_resources: ready_probe → init_leader → join_followers → post_init (KV-v2 + userpass + AppRole + smoke secret) |
| `terraform/envs/foundation/role-overlay-gateway-vault-reservations.tf` | dnsmasq `dhcp-host` reservations on nexus-gateway pinning Vault MACs to canonical `.121/.122/.123` (gated on `var.enable_vault_dhcp_reservations`, default `false`) |
| `terraform/modules/vm/` | Extended for **dual-NIC** mode — optional `vnet_secondary` + `mac_secondary` vars; `scripts/configure-vm-nic.ps1` writes ethernet1 alongside ethernet0 |
| `scripts/foundation.ps1` / `scripts/security.ps1` | pwsh-native operator wrappers (canonical on Windows per [`memory/feedback_build_host_pwsh_native.md`](memory/feedback_build_host_pwsh_native.md)) |
| `scripts/smoke-0.D.1.ps1` | 24+ check smoke gate — cluster up, raft peers = 3, KV-v2 mounted, auth methods enabled, smoke secret readable from leader + both followers, build-host SSH/22 + 8200 reachable for all 3 nodes |

### 1g.1 Operator order (must follow)

The Vault clones depend on the gateway's `dhcp-host` reservations being live BEFORE they DHCP, otherwise they land in the dynamic `.200-.250` pool and get the wrong IPs. Operator sequence:

```powershell
# 1. Build the vault Packer template (one-time, ~10-15 min)
cd packer\vault
packer init .
packer build .

# 2. Apply foundation env WITH the Vault dhcp-host reservations enabled
cd ..\..
pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_dhcp_reservations=true

# 3. Apply security env (clones boot, get canonical .121/.122/.123 via the reservations,
#    cluster bring-up overlay runs init/unseal/raft-join/KV/auth)
pwsh -File scripts\security.ps1 apply

# 4. Verify
pwsh -File scripts\security.ps1 smoke
```

Or as a chained cycle once the template + foundation reservations are in place:

```powershell
pwsh -File scripts\security.ps1 cycle      # destroy -> apply -> smoke
```

### 1g.2 Selective ops

```powershell
# Bare clones, no init (iterate on the vault Packer template without re-running cluster bring-up)
pwsh -File scripts\security.ps1 apply -Vars enable_vault_init=false

# Single-node iteration
terraform -chdir=terraform\envs\security apply -target=module.vault_1

# Iterate on a single overlay step
terraform -chdir=terraform\envs\security apply -target=null_resource.vault_init_leader

# Re-fire a step after fixing something
terraform -chdir=terraform\envs\security taint null_resource.vault_post_init
terraform -chdir=terraform\envs\security apply -target=null_resource.vault_post_init

# Tear down whole env (clones go away; gateway dhcp-host reservations stay
# until you also disable enable_vault_dhcp_reservations on foundation)
pwsh -File scripts\security.ps1 destroy
```

### 1g.3 Build-host reachability invariant

Per [`memory/feedback_lab_host_reachability.md`](memory/feedback_lab_host_reachability.md), every Vault node must remain SSH/22 + Vault API/8200 reachable from the build host:

```powershell
foreach ($ip in @('192.168.70.121', '192.168.70.122', '192.168.70.123')) {
    foreach ($port in @(22, 8200)) {
        Test-NetConnection $ip -Port $port -InformationLevel Quiet
    }
}
```

Six True results = invariant intact. The smoke gate runs these as its first checks.

### 1g.4 Initial credentials

Init keys + root token land in `$HOME\.nexus\vault-init.json` on the build host (mode 0600 equivalent — NTFS owner-only ACL). **This is the only copy** — back it up before destroying the env. Rotation flow lands in 0.D.4 alongside foundation env's bootstrap creds.

```powershell
# Operator quick-access
$initJson = Get-Content $HOME\.nexus\vault-init.json | ConvertFrom-Json
$initJson.root_token            # for direct vault CLI use
$initJson.unseal_keys_b64       # 5 keys, threshold 3

# Default userpass (post-Phase 0.D.4 rotated to a Vault-managed cred)
# user: nexusadmin
# pass: NexusVaultOps!1 (per terraform/envs/security/variables.tf default)
```

### 1g.5 Operating Vault from the build host

Until 0.D.2 issues PKI certs, Vault uses self-signed bootstrap TLS. To use the Vault CLI from the build host:

```powershell
# Install Vault CLI (one-time):
# Download https://releases.hashicorp.com/vault/<version>/vault_<ver>_windows_amd64.zip,
# extract to $HOME\bin, add to $PATH

$env:VAULT_ADDR = 'https://192.168.70.121:8200'
$env:VAULT_SKIP_VERIFY = 'true'
$env:VAULT_TOKEN = (Get-Content $HOME\.nexus\vault-init.json | ConvertFrom-Json).root_token

vault status
vault secrets list
vault kv get nexus/smoke/canary
vault operator raft list-peers

# Phase 0.D.2 replaces VAULT_SKIP_VERIFY with proper VAULT_CACERT pointing at
# the PKI root.
```

### 1g.6 NOT in scope for 0.D.1 (deferred to 0.D.2-5)

Per the 0.D scope tracking commitment in [`memory/project_nexus_infra_phase.md`](memory/project_nexus_infra_phase.md):

- **0.D.2** — PKI mount + intermediate CA + Vault re-issues its own TLS cert from PKI; CA distribution to build host + future templates
- **0.D.3** — AD/LDAP auth method (Vault binds to dc-nexus on TCP/389) + AD secret engine for AD svc account password rotation
- **0.D.4** — Migrate foundation env's plaintext bootstrap creds (DSRM, local Administrator, nexusadmin) into Vault KV at `nexus/foundation/...`; refactor 0.C.* role overlays to read via `vault_kv_secret_v2` data sources
- **0.D.5** — Vault Transit auto-unseal + GMSA managed-service-accounts + tighten foundation `MinPasswordLength=14` + Vault Agent on member servers
- **Tail housekeeping** — update `nexus-platform-plan/docs/infra/vms.yaml` with the 2 GB RAM correction so canon matches observed-sufficient sizing

### 1g.7 RAM budget

| Component | Allocation | Cumulative |
|---|---|---|
| nexus-gateway | 512 MB | 0.5 GB |
| dc-nexus | 4 GB (ws2025-desktop default) | 4.5 GB |
| nexus-jumpbox | 4 GB (skippable via `enable_jumpbox_domain_join=false`) | 8.5 GB (or 4.5 GB if jumpbox skipped) |
| vault-1, vault-2, vault-3 | 2 GB × 3 = 6 GB | 14.5 GB (or 10.5 GB if jumpbox skipped) |

Skipping jumpbox during Vault iteration is the recommended default (jumpbox is operator UX; not needed for 0.D.1 itself):

```powershell
pwsh -File scripts\foundation.ps1 apply -Vars enable_jumpbox_domain_join=false,enable_vault_dhcp_reservations=true
pwsh -File scripts\security.ps1 cycle
```

---

## 1h. Phase 0.D.2 — `envs/security` PKI overlay

Layered on top of §1g. Mounts Vault PKI (`pki/` root + `pki_int/` intermediate), defines a `vault-server` issuing role, reissues each Vault listener cert from `pki_int/` (atomic-swap + SIGHUP — zero-downtime), distributes the root CA to the build host (operator drops `VAULT_SKIP_VERIFY` + sets `VAULT_CACERT`) and to every Vault node's system trust store, and retires the per-clone trust shuffle that 0.D.1 needed for cold-start raft join.

**Canon mapping** (per [`memory/feedback_master_plan_authority.md`](../memory/feedback_master_plan_authority.md)):

| Choice | Source |
|---|---|
| Vault PKI is in scope for Phase 0.D | [`docs/architecture.md`](architecture.md) line 122 ("Phase 0.D — Vault — bootstraps a 3-node Vault Raft cluster; cert issuance moves to Vault PKI") |
| No new VMs in 0.D.2 | `nexus-platform-plan/docs/infra/vms.yaml` foundation cluster lists vault-1/2/3 only |
| pwsh-native operator wrappers | [`memory/feedback_build_host_pwsh_native.md`](../memory/feedback_build_host_pwsh_native.md) |
| Selective per-step toggles (`enable_vault_pki_*`) | [`memory/feedback_selective_provisioning.md`](../memory/feedback_selective_provisioning.md) |
| Build-host SSH/22 + 8200 stays reachable across cert rotation | [`memory/feedback_lab_host_reachability.md`](../memory/feedback_lab_host_reachability.md) — SIGHUP reload preserves listening sockets |
| Root CN "NexusPlatform Root CA" / Intermediate CN "NexusPlatform Intermediate CA" | (canon-silent — chosen to identify the lab portfolio root) |
| Root TTL 10y / Intermediate TTL 5y / Leaf TTL 1y | (canon-silent — test-enterprise lab; Vault Agent-driven shorter rotation lands in 0.D.5) |
| Root CA bundle at `$HOME\.nexus\vault-ca-bundle.crt` | (canon-silent — mirrors operator-private location of `vault-init.json`) |

**Files (added in 0.D.2):**

| Path | Purpose |
|---|---|
| `terraform/envs/security/role-overlay-vault-pki-mount.tf` | Step 1: mount `pki/` (max_lease_ttl 10y) + `pki_int/` (max_lease_ttl 5y) |
| `terraform/envs/security/role-overlay-vault-pki-root.tf` | Step 2: generate root CA (CN "NexusPlatform Root CA"), set issuing/CRL URLs |
| `terraform/envs/security/role-overlay-vault-pki-intermediate.tf` | Step 3: generate CSR at `pki_int/` → sign via root → set-signed → URLs config |
| `terraform/envs/security/role-overlay-vault-pki-roles.tf` | Step 4: define `pki_int/roles/vault-server` (allowed_domains nexus.lab + vault-1/2/3 + FQDNs + localhost; `allow_ip_sans=true`; RSA-4096; 1y TTL) |
| `terraform/envs/security/role-overlay-vault-pki-rotate.tf` | Step 5: per-node `pki_int/issue/vault-server` → atomic-swap into `/etc/vault.d/tls/` → `systemctl reload vault.service` (SIGHUP) → verify post-reload via `openssl s_client`. Idempotent: skip if cert is PKI-issued and >30d remaining. |
| `terraform/envs/security/role-overlay-vault-pki-distribute.tf` | Step 6: write root CA to build host `$HOME\.nexus\vault-ca-bundle.crt` + install on each Vault node's system trust store at `/usr/local/share/ca-certificates/nexus-vault-pki-root.crt` |
| `terraform/envs/security/role-overlay-vault-pki-cleanup-hack.tf` | Step 7: remove `/usr/local/share/ca-certificates/vault-leader.crt` (the 0.D.1 cold-start residue) from followers — shared root CA is now the sole trust anchor |
| `scripts/smoke-0.D.2.ps1` | New smoke gate — chains `smoke-0.D.1.ps1` first, then layers PKI checks (engines mounted, root + intermediate CN match + chain validates, role configured, per-node listener cert SAN+TTL+issuer correct, build-host CA bundle hash-matches PKI root, .NET TLS handshake validates against bundle, legacy trust anchor pruned, shared root present on every node) |

### 1h.1 Operator order

Same order as 0.D.1. The PKI overlays run as part of the same `terraform apply` (security env), gated by `var.enable_vault_pki` (default true). No extra step:

```powershell
# 1. Build the vault Packer template (one-time, ~10-15 min)
cd packer\vault
packer init .
packer build .

# 2. Apply foundation env WITH the Vault dhcp-host reservations enabled
cd ..\..
pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_dhcp_reservations=true

# 3. Apply security env (clones boot, 0.D.1 cluster bring-up, then 0.D.2 PKI bootstrap + rotate + distribute + cleanup)
pwsh -File scripts\security.ps1 apply

# 4. Smoke gate (defaults to 0.D.2 -- chains 0.D.1 first, then PKI checks)
pwsh -File scripts\security.ps1 smoke
```

Or as a chained cycle:

```powershell
pwsh -File scripts\security.ps1 cycle      # destroy -> apply -> smoke (0.D.2)
```

### 1h.2 Selective ops

```powershell
# Run 0.D.1 only -- skip the entire PKI overlay
pwsh -File scripts\security.ps1 apply -Vars enable_vault_pki=false
pwsh -File scripts\security.ps1 smoke -Phase 0.D.1

# PKI mounts + CAs but no leaf rotation (e.g. iterating on the role definition)
pwsh -File scripts\security.ps1 apply -Vars enable_vault_pki_rotate=false

# Iterate on a single PKI step
terraform -chdir=terraform\envs\security apply -target=null_resource.vault_pki_intermediate_ca
terraform -chdir=terraform\envs\security taint  null_resource.vault_pki_rotate_listener
terraform -chdir=terraform\envs\security apply  -target=null_resource.vault_pki_rotate_listener
```

### 1h.3 Build-host reachability invariant (post-PKI)

SIGHUP reload preserves the vault.service listening socket — TCP connections aren't dropped during cert swap. Reachability invariant unchanged from 0.D.1:

```powershell
foreach ($ip in @('192.168.70.121', '192.168.70.122', '192.168.70.123')) {
    foreach ($port in @(22, 8200)) {
        Test-NetConnection $ip -Port $port -InformationLevel Quiet
    }
}
```

Six True results = invariant intact. The 0.D.2 smoke gate carries forward this check.

### 1h.4 Operating Vault from the build host (post-PKI)

Drop `VAULT_SKIP_VERIFY` and set `VAULT_CACERT`:

```powershell
$env:VAULT_ADDR   = 'https://192.168.70.121:8200'
$env:VAULT_CACERT = "$HOME\.nexus\vault-ca-bundle.crt"
$env:VAULT_TOKEN  = (Get-Content $HOME\.nexus\vault-init.json | ConvertFrom-Json).root_token

vault status
vault read pki/cert/ca           # root CA
vault read pki_int/cert/ca       # intermediate CA
vault read pki_int/roles/vault-server
vault list pki_int/issuers
vault kv get nexus/smoke/canary
```

Issue a one-off cert from the role (e.g. for ad-hoc testing or a future template):

```powershell
vault write pki_int/issue/vault-server `
  common_name=vault-1.nexus.lab `
  alt_names=vault-1,localhost `
  ip_sans=192.168.70.121,192.168.10.121,127.0.0.1 `
  ttl=24h
```

### 1h.5 Cert rotation lifecycle

| Event | Behavior |
|---|---|
| `terraform apply` with cert >30d remaining + already PKI-issued | Rotate step is no-op (idempotency probe). |
| `terraform apply` with cert <30d remaining | Rotate step issues fresh cert, atomic-swaps, SIGHUPs, verifies. |
| `terraform taint null_resource.vault_pki_rotate_listener` + apply | Forces re-rotation regardless of remaining days. |
| Vault node clone replaced (e.g. `terraform destroy -target=module.vault_2` + `apply`) | Fresh clone gets self-signed bootstrap cert via `vault-firstboot.sh` first; cluster bring-up rejoins the node; PKI rotate overlay then issues a PKI-signed cert and replaces the bootstrap. The legacy trust shuffle on rejoin (cluster overlay) installs the leader's PKI-issued cert in the new clone's system trust store as the cold-start anchor; the cleanup overlay then prunes it once the shared root is in place. |
| Manual cert reissue via Vault CLI | Allowed (operator-time issuance via `vault write pki_int/issue/...`); but the listener won't pick it up unless the operator writes the new cert/key to `/etc/vault.d/tls/` and SIGHUPs vault.service. The rotate overlay handles all of this declaratively. |

### 1h.6 NOT in scope for 0.D.2 (deferred)

Per the 0.D scope tracking commitment in [`memory/project_nexus_infra_phase.md`](../memory/project_nexus_infra_phase.md):

- **0.D.3** — AD/LDAP auth method (Vault binds to dc-nexus on TCP/389) + AD secret engine for AD svc account password rotation
- **0.D.4** — Migrate foundation env's plaintext bootstrap creds (DSRM, local Administrator, nexusadmin) into Vault KV at `nexus/foundation/...`; refactor 0.C.* role overlays to read via `vault_kv_secret_v2` data sources
- **0.D.5** — Vault Transit auto-unseal + GMSA managed-service-accounts + tighten foundation `MinPasswordLength=14` + Vault Agent on member servers (Vault Agent is what enables short-TTL leaf certs with auto-renewal — not required at 1y leaf TTL)
- **mTLS between Vault and clients** — Phase 0.D.5+ (PKI provides the issuance machinery; client identity policy is a separate layer)
- **Cross-cluster trust** — not in scope for a 3-node single-cluster lab
- **Tail housekeeping** — update `nexus-platform-plan/docs/infra/vms.yaml` with the 2 GB RAM correction so canon matches observed-sufficient sizing (carried forward from 0.D.1)

### 1h.7 RAM budget (unchanged)

0.D.2 adds no VMs. RAM accounting is identical to §1g.7.

---

## 1i. Phase 0.D.3 — `envs/foundation` AD objects + `envs/security` LDAP overlay

First phase that spans **both envs**. Foundation creates AD service accounts + groups for Vault to consume; security configures Vault `auth/ldap` (humans login with AD credentials) + `secrets/ldap` (Vault rotates AD svc account passwords). Cross-env state exchanges via `$HOME\.nexus\vault-ad-bind.json` on the build host (mirrors `vault-init.json` and `vault-ca-bundle.crt` shape).

**Canon mapping** (per [`memory/feedback_master_plan_authority.md`](../memory/feedback_master_plan_authority.md)):

| Choice | Source |
|---|---|
| Vault is the auth/secret-management plane | `MASTER-PLAN.md` Phase 0.D (line 145) |
| AD DS forest `nexus.lab` exists on dc-nexus | foundation env 0.C.2 + [`memory/feedback_addsforest_post_promotion.md`](../memory/feedback_addsforest_post_promotion.md) |
| OU=ServiceAccounts, OU=Groups already exist | foundation env 0.C.4 hardening (`role-overlay-dc-ous.tf`) |
| Cross-env state via `$HOME\.nexus\*.json` | (canon-silent) — operator-private dir convention; mirrors `vault-init.json` (0.D.1) and `vault-ca-bundle.crt` (0.D.2) |
| AD/LDAP integration specifics (group names, bind account name, policy shape) | (canon-silent) — extending the plan with conservative defaults that don't preclude future canon, per `feedback_master_plan_authority.md` rule 4 |
| Plain LDAP/389 (not LDAPS/636) | user-approved 2026-05-01 — LDAPS is a 0.D.5 tightening, after the PKI-issued DC cert + AD-side cert configuration |

**Files (added in 0.D.3):**

| Path | Purpose |
|---|---|
| `terraform/envs/foundation/role-overlay-dc-vault-ad-bind.tf` | Create AD svc account `svc-vault-ldap` in `OU=ServiceAccounts`; generate strong random pwd locally; write `$HOME\.nexus\vault-ad-bind.json` (mode 0600 via icacls) |
| `terraform/envs/foundation/role-overlay-dc-vault-groups.tf` | Create AD security groups `nexus-vault-admins`, `nexus-vault-operators`, `nexus-vault-readers` in `OU=Groups`; enroll `nexusadmin` into admins |
| `terraform/envs/foundation/role-overlay-dc-vault-demo-rotated-account.tf` | Create `svc-demo-rotated` (target of Vault's static rotate-role); initial pwd is random; Vault owns it from first rotation onward |
| `terraform/envs/foundation/role-overlay-dc-vault-smoke-account.tf` | Create `svc-vault-smoke` (read-only AD test account); enrol in `nexus-vault-readers`; persist plaintext smoke pwd in `vault-ad-bind.json` for the smoke gate's end-to-end LDAP login probe |
| `terraform/envs/security/role-overlay-vault-ldap-policies.tf` | Define Vault policies `nexus-admin` (full sudo), `nexus-operator` (R/W on nexus/* + cert issuance via pki_int/issue/*), `nexus-reader` (read-only on nexus/*) |
| `terraform/envs/security/role-overlay-vault-ldap-auth.tf` | Enable + configure `auth/ldap` (URL, binddn, bindpass from JSON, userdn/groupdn) + group→policy mappings |
| `terraform/envs/security/role-overlay-vault-ldap-secret-engine.tf` | Enable `secrets/ldap` (unified AD/OpenLDAP engine, GA in Vault 1.12+) + define password policy `nexus-ad-rotated` (24-char, mixed) |
| `terraform/envs/security/role-overlay-vault-ldap-rotate-role.tf` | Define static rotate-role for `svc-demo-rotated` with `rotation_period=24h` |
| `scripts/smoke-0.D.3.ps1` | New smoke gate — chains 0.D.2 first, then ~12 LDAP checks (DC reachability, auth/ldap config, group mappings, policies, end-to-end LDAP login probe via `svc-vault-smoke`, secret engine config, static rotate-role + cred lookup) |

### 1i.1 Operator order

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware"

# 1. Foundation env -- enable AD-side Vault objects (AD svc accounts + groups + demo + smoke account)
pwsh -File scripts\foundation.ps1 apply `
  -Vars enable_vault_dhcp_reservations=true,enable_vault_ad_integration=true,enable_jumpbox_domain_join=false

# 2. Security env -- cycle including new LDAP overlays (auto-reads vault-ad-bind.json)
pwsh -File scripts\security.ps1 cycle      # smoke now defaults to 0.D.3 (chains 0.D.2 -> 0.D.1)
```

### 1i.2 Selective ops

```powershell
# 0.D.1 cluster only (no PKI, no LDAP)
pwsh -File scripts\security.ps1 apply -Vars enable_vault_pki=false,enable_vault_ldap=false
pwsh -File scripts\security.ps1 smoke -Phase 0.D.1

# 0.D.1 + 0.D.2 PKI (no LDAP)
pwsh -File scripts\security.ps1 apply -Vars enable_vault_ldap=false
pwsh -File scripts\security.ps1 smoke -Phase 0.D.2

# Iterate on a single LDAP overlay
terraform -chdir=terraform\envs\security taint  null_resource.vault_ldap_auth
terraform -chdir=terraform\envs\security apply  -target=null_resource.vault_ldap_auth -auto-approve

# Force-rotate the demo AD account's password (vault read returns the new pwd)
ssh nexusadmin@192.168.70.121 "VAULT_TOKEN='<root>' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault write -f ldap/rotate-role/svc-demo-rotated"

# Rotate the bind account password (use sparingly -- must re-apply security env after)
pwsh -File scripts\foundation.ps1 apply -Vars enable_vault_ad_integration=true,enable_vault_ad_bind_rotate_password=true
pwsh -File scripts\security.ps1 apply
```

### 1i.3 Operating Vault from the build host (post-LDAP)

```powershell
# Operator login via AD credentials -- replaces root token for daily use
$env:VAULT_ADDR   = 'https://192.168.70.121:8200'
$env:VAULT_CACERT = "$HOME\.nexus\vault-ca-bundle.crt"

vault login -method=ldap -username=nexusadmin
# Prompts for AD password (or pass -password='...'); returns a token whose
# policies are derived from your AD group memberships.

# Read the current Vault-managed password for the demo AD account
vault read ldap/static-cred/svc-demo-rotated
# Returns: { username, password, last_vault_rotation, ttl, ... }

# Force-rotate (root or nexus-admin policy required)
vault write -f ldap/rotate-role/svc-demo-rotated
```

### 1i.4 Adding a new AD-driven policy mapping

```powershell
# 1. Create the AD group (foundation env or manually via RSAT on jumpbox)
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "New-ADGroup -Name nexus-vault-pki-admins -GroupScope Global -GroupCategory Security -Path OU=Groups,DC=nexus,DC=lab"'

# 2. Add an AD user to it
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Add-ADGroupMember -Identity nexus-vault-pki-admins -Members alice"'

# 3. Define a Vault policy
$policy = @"
path "pki/*" { capabilities = ["create","read","update","delete","list"] }
path "pki_int/*" { capabilities = ["create","read","update","delete","list"] }
"@
$policy | ssh nexusadmin@192.168.70.121 'cat > /tmp/p.hcl && VAULT_TOKEN=<root> VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault policy write nexus-pki-admin /tmp/p.hcl && rm /tmp/p.hcl'

# 4. Map the AD group -> policy
ssh nexusadmin@192.168.70.121 "VAULT_TOKEN=<root> VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault write auth/ldap/groups/nexus-vault-pki-admins policies=nexus-pki-admin"

# Now alice can `vault login -method=ldap -username=alice` and get the nexus-pki-admin policy.
```

### 1i.5 NOT in scope for 0.D.3 (deferred)

- **0.D.4** — migrate foundation plaintext bootstrap creds (DSRM, local Administrator, nexusadmin) into Vault KV; refactor 0.C.* role overlays to read via `vault_kv_secret_v2` data sources
- **0.D.5** — Transit auto-unseal + GMSA + tighten foundation `MinPasswordLength=14` + Vault Agent on member servers (where short-TTL leaf cert auto-rotation lands; also where LDAPS replaces plain LDAP/389)
- **mTLS Vault clients** — Phase 0.D.5+
- **Multi-realm AD trust** — not in scope for a single-forest lab
- **Tail housekeeping** — `vms.yaml` 2 GB RAM correction + `vault-firstboot.sh` /etc/hosts fix (committed; awaits next template rebuild)

### 1i.6 RAM budget (unchanged)

0.D.3 adds no VMs. RAM accounting identical to §1g.7.

---

## 2. Working with the running gateway

### 2.1 SSH in

```powershell
# Assumes §0.4 SSH client setup is done (~/.ssh/config + ssh-add).
# Otherwise: ssh -i $HOME\.ssh\nexus_gateway_ed25519 nexusadmin@192.168.70.1
ssh nexusadmin@192.168.70.1
```

Key auth uses the pubkey baked into the gateway template at build time (`packer/nexus-gateway/ansible/roles/nexus_gateway/files/nexusadmin.pub`). Build-time password (`packer/nexus-gateway/variables.pkr.hcl` `ssh_password = "nexus-packer-build-only"`) is still enabled on the running gateway as a fallback — Phase 0.D will rotate it out when Vault comes up.

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
├── Makefile                    # Linux/WSL/CI targets (gateway, *-apply, *-destroy, *-smoke); on Windows use `scripts/<env>.ps1` wrappers instead
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
    ├── ws2025-core-smoke/      # Phase 0.B.4 — smoke harness for ws2025-core
    ├── ws2025-desktop-smoke/   # Phase 0.B.5 — smoke harness for ws2025-desktop
    ├── win11ent-smoke/         # Phase 0.B.6 — smoke harness for win11ent
    └── envs/
        └── foundation/                              # Phase 0.C.1 — always-on plumbing (dc-nexus + nexus-jumpbox)
            ├── main.tf                              # 2 modules/vm/ instances
            ├── variables.tf                         # MAC + AD DS + selective-toggle vars
            ├── outputs.tf                           # vm_paths, mac_addresses, domain_info, jumpbox_info, next_step
            ├── role-overlay-dc-nexus.tf             # Phase 0.C.2 — rename + Install-ADDSForest + post-promote remediation
            ├── role-overlay-gateway-dns.tf          # Phase 0.C.2 — env-scoped dnsmasq forward for nexus.lab
            └── role-overlay-jumpbox-domainjoin.tf   # Phase 0.C.3 — Add-Computer nexus-jumpbox → nexus.lab
```

Template VMs live at `H:\VMS\NexusPlatform\_templates\<name>\<name>.vmx`.
Running instances at `H:\VMS\NexusPlatform\<tier>\<name>\<name>.vmx` (tier = `00-edge`, `01-foundation`, `20-apps`, …; tiers per `nexus-platform-plan/docs/infra/vms.yaml`).

---

## 6. What's next

| Phase | Task | Doc |
|-------|------|-----|
| 0.B.1 | ✅ nexus-gateway | [nexus-gateway.md](nexus-gateway.md) |
| 0.B.2 | ✅ Debian 13 base template + reusable `modules/vm/` | [deb13.md](deb13.md) |
| 0.B.3 | ✅ Ubuntu 24.04 LTS base template + DRY `_shared/` roles (`nexus_identity`, `nexus_network`, `nexus_firewall`, `nexus_observability`) | [ubuntu24.md](ubuntu24.md) |
| 0.B.4 | ✅ Windows Server 2025 Core template (first Windows image; WinRM-build / OpenSSH-runtime; PowerShell provisioners parallel to the Linux shared roles) | [ws2025-core.md](ws2025-core.md) |
| 0.B.5 | ✅ Windows Server 2025 Desktop template + DRY `_shared/powershell/` extraction | [ws2025-desktop.md](ws2025-desktop.md) |
| 0.B.6 | ✅ Windows 11 Enterprise template (vTPM bypass via LabConfig; LATFP + elevated_user; pinned Win32-OpenSSH v9.5) | [win11ent.md](win11ent.md) |
| 0.C.1 | ✅ `envs/foundation` — always-on plumbing (dc-nexus + nexus-jumpbox); zero-touch SSH smoke green | §1c above |
| 0.C.2 | ✅ AD DS role overlay on dc-nexus (`Install-ADDSForest -DomainName nexus.lab`) + env-scoped dnsmasq forward + post-promotion remediation (v4) | §1d above |
| 0.C.3 | ✅ `nexus-jumpbox` domain-join to `nexus.lab` — fully reproducible end-to-end (`destroy` + `apply` cycle ~16 min, unattended) | §1e above |
| 0.C.* | `envs/{data,ml,saas,microservices,demo-minimal}` — composing per-template clones into role fleets | *(pending)* |
| 0.D   | Vault + SSH key rotation + KMIP for real vTPM + DSRM password rotation | *(pending)* |
| 0.E   | Consul KV terraform backend (replaces local `.tfstate`) | *(pending)* |

Keep this file in sync as phases land — each new VM gets a per-VM doc under `docs/` and a section added here under §1.
