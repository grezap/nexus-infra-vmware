# ubuntu24 — design + runbook

**Generic Ubuntu 24.04 LTS base template.** The second general-purpose base image in the lab, parallel to [`deb13`](./deb13.md). Used for VMs that want Canonical's userspace or a newer kernel line than Debian 13 ships (candidates: MinIO with io_uring tuning, Spark workers with JVM + recent native libs, Jupyter servers, anything pinned to Noble Numbat's glibc/LLVM).

## Why a second base template

Two reasons:

1. **Kernel + userspace choice.** Debian 13 and Ubuntu 24.04 LTS have different kernel cadences (Ubuntu ships HWE stacks), different glibc lines, and different default init configurations. Workloads tuned against one can regress on the other. Having both available means every role in the lab picks the right parent on technical grounds, not "the one we happened to build first."
2. **Forces the DRY extraction.** With only `deb13`, the baseline (NIC rename, nftables, chrony, node_exporter, sshd hardening, host-key regen) lives in one `debian_base` role — fine, no pressure to abstract. The second template is the forcing function for [`_shared/ansible/roles/`](../packer/_shared/ansible/roles/) — two concrete call sites let us pick the right abstraction instead of guessing. That's the Phase 0.B.3 step 2 deliverable.

## What the template ships

Byte-for-byte identical behaviour to `deb13` for everything in the shared baseline (see [deb13.md → What the template ships](./deb13.md#what-the-template-ships)), plus three Ubuntu-specific items:

| Component                                    | Status at build time | First-boot behavior |
|----------------------------------------------|----------------------|---------------------|
| `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` | Dropped (`network: {config: disabled}`) | cloud-init skips netplan regeneration; our systemd-networkd config owns nic0 |
| `/etc/netplan/50-cloud-init.yaml`            | Removed               | No netplan config races our `.link`/`.network` |
| `/etc/update-motd.d/*` (Landscape ads, ESM nag, release-upgrade prompts) | Marked non-executable (chmod 0644) | SSH login shows only our `/etc/motd` — no Canonical nag screens |

Everything else is shared-baseline-identical:
- `nexusadmin` sudoer + owner pubkey
- `systemd-networkd` `OriginalName=en*` → `nic0` with DHCP
- `nftables` deny-in + SSH/9100 from VMnet11
- `chrony` client pointed at `192.168.70.1` with `ntp.ubuntu.com` fallback
- `prometheus-node-exporter` on `:9100`
- `unattended-upgrades` — **Ubuntu origin pattern** (`${distro_id}:${distro_codename}-security` + ESM variants), *not* Debian's
- Hardened `sshd` via `sshd_config.d/10-nexus-hardening.conf` drop-in
- SSH host-key regen drop-in (`ExecStartPre=` cleared then re-ordered so `ssh-keygen -A` runs before `sshd -t`)
- `/etc/machine-id` + `/etc/ssh/ssh_host_*` removed at build; regenerated on first boot

## What the template does **not** ship

Same list as `deb13`:
- No dnsmasq, no DHCP server, no `ip_forward`, no masquerade — that's `nexus-gateway`'s job.
- No OpenTelemetry Collector — deferred to Phase 0.I's `nexus_observability` role expansion.
- No snap services beyond what autoinstall includes by default (snapd itself is kept because it's tangled into the live-server installer, but no snaps are seeded).
- No database, no app runtime, no TLS tooling — role overlays add those per-VM.

## Build + deploy

Prerequisites — same as `deb13`:
- Phase 0.B.1 complete (nexus-gateway running at `192.168.70.1`).
- `H:/VMS/NexusPlatform/_templates/` directory writable.

```powershell
# 1. Build the template (~10–15 min — autoinstall is slower than preseed)
cd "F:\_CODING_\…\nexus-infra-vmware"
make ubuntu24
# Template lands at H:\VMS\NexusPlatform\_templates\ubuntu24\ubuntu24.vmx

# 2. Smoke-test via the reusable module (~10 sec)
make ubuntu24-smoke
# VM lands at H:\VMS\NexusPlatform\90-smoke\ubuntu24-smoke\ubuntu24-smoke.vmx

# 3. Find its DHCP lease (issued by nexus-gateway's dnsmasq)
ssh nexusadmin@192.168.70.1 "awk '\$2==\"00:50:56:3f:00:21\" {print \$3}' /var/lib/misc/dnsmasq.leases"

# 4. Probe it directly (replace <ip> with the lease from step 3)
Test-NetConnection <ip> -Port 22
Test-NetConnection <ip> -Port 9100
ssh nexusadmin@<ip>

# 5. Tear down
make ubuntu24-smoke-destroy
```

## Verification checklist

Inside the smoke-test VM — identical to deb13's checks:

```bash
# NIC renamed correctly
ip -br link           # expect `nic0` UP with DHCP-assigned IP

# Time synced via the gateway
chronyc sources -v    # 192.168.70.1 should show as the preferred source

# nftables loaded
sudo nft list ruleset | head -40

# node_exporter responds on :9100
curl -s localhost:9100/metrics | head -5

# DNS works (forwarded by nexus-gateway's dnsmasq)
nslookup ubuntu.com

# cloud-init did NOT regenerate netplan config
ls /etc/netplan/      # should be empty or missing 50-cloud-init.yaml

# MOTD is the NexusPlatform banner, no Canonical nag screens
cat /etc/motd         # NexusPlatform frame
ssh nexusadmin@<ip> true  # login banner = /etc/motd only
```

## Design decisions worth remembering

### Autoinstall via GRUB `c` + hand-loaded kernel

The `boot_command` drops into GRUB's command shell (`c`), hand-loads the live-server kernel + initrd from `/casper/`, and passes `autoinstall ds="nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/"` as kernel args. This is the canonical Packer-for-Ubuntu-autoinstall pattern — it avoids depending on ISO-specific GRUB menu entry positioning (which can shift between point releases and break key-sequence boot commands).

The `nocloud-net` data source tells cloud-init to pull `user-data` + `meta-data` (empty file, required) from Packer's built-in HTTP server.

### Why `cloud-init network: disabled`

Without this file, cloud-init regenerates `/etc/netplan/*.yaml` on every boot, pointed at whatever NIC name it last saw (`ens33`, etc.). Our systemd `.link` file renames that NIC to `nic0` — but by then netplan has already tried to apply a config for the old name, leading to a visible window where the NIC has no IP. Disabling cloud-init's network config generator makes systemd-networkd the sole authority, and the baseline becomes deterministic.

### Removing `/etc/netplan/50-cloud-init.yaml` at build time

The file exists from Subiquity's install step, pointing at `ens*` with `dhcp4: true`. Even with cloud-init's network config disabled going forward, the already-written file would cause `netplan generate` to emit conflicting systemd-networkd configs on first boot. Removing it at build time closes that gap.

### MOTD scrubbing

Ubuntu's `pam_motd` pulls from `/etc/update-motd.d/` — dynamic scripts that inject Landscape adverts, ESM upgrade pitches, "XX updates can be applied" banners, and release-upgrade prompts. Making those scripts non-executable (`chmod 0644`) keeps them on-disk for audit but disables execution. `pam_motd` then falls back to static `/etc/motd`, which we own. Uses `failed_when: false` because not every minor release ships all the same scripts.

### Shared parts with deb13 — the Phase 0.B.3 step 2 DRY extraction

With two concrete call sites (not one) the abstraction picks itself: everything behaviourally identical between `debian_base` and `ubuntu_base` lifts into four generic roles under [`packer/_shared/ansible/roles/`](../packer/_shared/ansible/roles/):

| Shared role             | Lifts                                                           |
|-------------------------|-----------------------------------------------------------------|
| `nexus_identity`        | nexusadmin pubkey → authorized_keys, sshd hardening drop-in, ssh.service ExecStartPre re-ordering (`ssh-keygen -A` before `sshd -t`) |
| `nexus_network`         | NIC rename `en*→nic0` + systemd-networkd + chrony client config |
| `nexus_firewall`        | nftables baseline (deny-in + SSH/9100 from VMnet11)             |
| `nexus_observability`   | prometheus-node-exporter (room reserved for OTel Collector at Phase 0.I) |

`debian_base` / `ubuntu_base` each shrink to the OS-specific tail:
- `debian_base`: apt package list + Debian-Security `unattended-upgrades` origin + MOTD
- `ubuntu_base`: apt package list + Ubuntu + ESM `unattended-upgrades` origins + cloud-init `network: {config: disabled}` + `/etc/netplan/50-cloud-init.yaml` removal + `/etc/update-motd.d/*` chmod 0644 + MOTD

Both Packer pkr.hcl files list the four `../_shared/ansible/roles/<name>` entries in `role_paths` alongside their OS-specific role; the ansible-local provisioner uploads each as its own role directory and `playbook.yml` references them by name. No symlinks, no `vendor/`, no submodules.

## Rebuild procedure

```powershell
cd "F:\_CODING_\…\nexus-infra-vmware"
make ubuntu24-smoke-destroy                                    # if a smoke VM exists
Remove-Item -Recurse -Force H:\VMS\NexusPlatform\_templates\ubuntu24 -ErrorAction SilentlyContinue
make ubuntu24                                                  # rebuild template
make ubuntu24-smoke                                            # verify
```
