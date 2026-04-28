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

# Find its lease + probe (assumes §0.4 SSH client setup; otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519`)
ssh nexusadmin@192.168.70.1 "grep '00:50:56:3f:00:20' /var/lib/misc/dnsmasq.leases"
200..250 | ForEach-Object { $ip="192.168.70.$_"; if (Test-Connection -Quiet -Count 1 $ip) { "UP: $ip" } }
Test-NetConnection <ip> -Port 22
Test-NetConnection <ip> -Port 9100
ssh nexusadmin@<ip>     # Linux remote shell defaults to bash — no wrapper needed

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

# Find its lease + SSH in (assumes §0.4 SSH client setup; otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519`)
ssh nexusadmin@192.168.70.1 "awk '\$2==\"00:50:56:3f:00:22\" {print \$3}' /var/lib/misc/dnsmasq.leases"
Test-NetConnection <ip> -Port 22      # OpenSSH (key-only)
Test-NetConnection <ip> -Port 9182    # windows_exporter
# Wrap PowerShell commands in `'powershell -NoProfile -Command "..."'` -- Win32-OpenSSH default remote shell is cmd.exe.
ssh nexusadmin@<ip> 'powershell -NoProfile -Command "hostname; (Get-Service sshd, windows_exporter).Status"'

make ws2025-core-smoke-destroy
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
| `dc-nexus`            | `ws2025-desktop`  | `00:50:56:3F:00:25` | `H:/VMS/NexusPlatform/10-core/dc-nexus`        | Domain controller (AD DS promotion = role overlay, deferred) |
| `nexus-admin-jumpbox` | `ws2025-desktop`  | `00:50:56:3F:00:26` | `H:/VMS/NexusPlatform/10-core/nexus-admin-jumpbox` | Operator jump host (RSAT / GPMC / DNS tools) |

Both clones DHCP from `nexus-gateway` on VMnet11 (192.168.70.0/24, .200–.250 range).

```powershell
cd "F:\_CODING_\Repos\Local Development And Test\Portfolio_Project_Ideas\workspace\nexus-infra-vmware"

# Pre-req: ws2025-desktop template must exist (Phase 0.B.5).
ls H:\VMS\NexusPlatform\_templates\ws2025-desktop\ws2025-desktop.vmx

# Deploy both VMs (~20 sec; 2 sequential clones)
make foundation-apply

# Tear down (stops both, deletes both)
make foundation-destroy
```

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

Verify nexus-admin-jumpbox has the operator toolset:

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
| `:26` | `nexus-admin-jumpbox` | `envs/foundation/`      |
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

Open the VM in Workstation GUI (`File → Open → H:\VMS\NexusPlatform\10-core\<vm>\<vm>.vmx`), login as `nexusadmin` (build-time password from `packer/ws2025-desktop/variables.pkr.hcl`), launch elevated PowerShell, then:

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

`nltest /dsgetdc:nexus.lab` from a non-domain-joined peer (e.g. the `nexus-admin-jumpbox` in its current workgroup state) returns `1355 ERROR_NO_SUCH_DOMAIN` even when the DC is fully functional. Reason: Netlogon service is dormant on workgroup machines; tools that depend on it can't auto-start it without a domain context. **Don't use nltest from workgroup peers as a smoke gate.** Use these instead:

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

Once `nexus-admin-jumpbox` is domain-joined (Phase 0.C.3), Netlogon auto-starts and stays running, after which `nltest /dsgetdc:nexus.lab` from the jumpbox works cleanly.

---

## 1e. Phase 0.C.3 — `nexus-admin-jumpbox` domain-join to `nexus.lab`

Layered on top of 0.C.2's promoted DC. Joins `nexus-admin-jumpbox` to the `nexus.lab` domain so it becomes a real domain member: operators authenticate as `nexus\nexusadmin` (or any future domain user), Group Policy can target it, RSAT tools work without explicit `-Credential`, and the cosmetic `nltest 1355` from §1d.6 disappears (Netlogon auto-starts post-join).

**File:** `terraform/envs/foundation/role-overlay-jumpbox-domainjoin.tf` — 3 sequential top-level `null_resource`s:

| Step | What it does |
|---|---|
| `jumpbox_domain_join` | Single base64-encoded SSH command that (a) patches sshd_config to drop `AllowUsers nexusadmin` so post-join SSH as `nexus\nexusadmin` works, then (b) `Add-Computer -DomainName nexus.lab -NewName nexus-admin-jumpbox -Credential <NEXUS\nexusadmin> -Force -Restart`. Add-Computer renames the local hostname AND adds to the domain in one atomic call. |
| `jumpbox_wait_rejoined` | Polls `(Get-WmiObject Win32_ComputerSystem).PartOfDomain` over SSH until True + Domain=nexus.lab. ~3-7 min wall-clock. |
| `jumpbox_verify` | Emits `Win32_ComputerSystem` membership state, `nltest /dsgetdc:nexus.lab` (now succeeds — Netlogon is live), and `Get-ADComputer nexus-admin-jumpbox` (proves the box is registered in AD). |

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
ssh nexusadmin@192.168.70.240 'powershell -NoProfile -Command "Get-ADComputer nexus-admin-jumpbox | Format-List Name, DNSHostName, DistinguishedName"'
```

**Idempotency:** the join script's first action over SSH is an idempotency check — `(Get-WmiObject).PartOfDomain` + `Domain == nexus.lab`. If both true, the script exits 0 and Add-Computer is never called. Re-applies are safe.

### 1e.1 NOT in scope for 0.C.3

- **OUs for organizing the jumpbox + future domain members** — Phase 0.C.4+
- **GPO for jumpbox lockdown** — Phase 0.C.4+
- **Removing the local `nexusadmin` from the jumpbox** — left in place as fallback during early lab phases; cleaned up when Phase 0.D rotates credentials via Vault
- **Joining `dc-nexus` to itself** (it's the DC; it's *the* domain authority by definition; no `Add-Computer` needed)

### 1e.2 Carries forward the post-AD lessons from §1d.4

The same `sshd_config AllowUsers` trap that bit us on dc-nexus also applies to any domain-joined Windows peer. The join overlay applies the same patch (drop the directive, restart sshd) BEFORE the Add-Computer reboot so the post-reboot sshd allows domain-format usernames immediately. Memory entry [`feedback_addsforest_post_promotion.md`](memory/feedback_addsforest_post_promotion.md) covers both DC and member-server cases — same trust model (pubkey + Administrators group), same fix.

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
    ├── ws2025-core-smoke/      # Phase 0.B.4 — smoke harness for ws2025-core
    ├── ws2025-desktop-smoke/   # Phase 0.B.5 — smoke harness for ws2025-desktop
    ├── win11ent-smoke/         # Phase 0.B.6 — smoke harness for win11ent
    └── envs/
        └── foundation/                              # Phase 0.C.1 — always-on plumbing (dc-nexus + nexus-admin-jumpbox)
            ├── main.tf                              # 2 modules/vm/ instances
            ├── variables.tf                         # MAC + AD DS + selective-toggle vars
            ├── outputs.tf                           # vm_paths, mac_addresses, domain_info, jumpbox_info, next_step
            ├── role-overlay-dc-nexus.tf             # Phase 0.C.2 — rename + Install-ADDSForest + post-promote remediation
            ├── role-overlay-gateway-dns.tf          # Phase 0.C.2 — env-scoped dnsmasq forward for nexus.lab
            └── role-overlay-jumpbox-domainjoin.tf   # Phase 0.C.3 — Add-Computer nexus-admin-jumpbox → nexus.lab
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
| 0.B.5 | ✅ Windows Server 2025 Desktop template + DRY `_shared/powershell/` extraction | [ws2025-desktop.md](ws2025-desktop.md) |
| 0.B.6 | ✅ Windows 11 Enterprise template (vTPM bypass via LabConfig; LATFP + elevated_user; pinned Win32-OpenSSH v9.5) | [win11ent.md](win11ent.md) |
| 0.C.1 | ✅ `envs/foundation` — always-on plumbing (dc-nexus + nexus-admin-jumpbox); zero-touch SSH smoke green | §1c above |
| 0.C.2 | ✅ AD DS role overlay on dc-nexus (`Install-ADDSForest -DomainName nexus.lab`) + env-scoped dnsmasq forward + post-promotion remediation (v4) | §1d above |
| 0.C.3 | 🔄 `nexus-admin-jumpbox` domain-join to `nexus.lab` — **scaffolded; first apply pending** | §1e above |
| 0.C.* | `envs/{data,ml,saas,microservices,demo-minimal}` — composing per-template clones into role fleets | *(pending)* |
| 0.D   | Vault + SSH key rotation + KMIP for real vTPM + DSRM password rotation | *(pending)* |
| 0.E   | Consul KV terraform backend (replaces local `.tfstate`) | *(pending)* |

Keep this file in sync as phases land — each new VM gets a per-VM doc under `docs/` and a section added here under §1.
