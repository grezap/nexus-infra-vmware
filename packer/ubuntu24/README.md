# packer/ubuntu24 — Ubuntu 24.04 LTS generic base template (Phase 0.B.3)

**Status:** 🚧 Phase 0.B.3 step 1 — template scaffolded. Second generic base template alongside [`packer/deb13`](../deb13/). Pair sets up the DRY extraction in step 2.

Shape-identical to `deb13` with three Ubuntu-specific differences:

1. **Installer** — Canonical Subiquity autoinstall (cloud-init NoCloud) instead of Debian d-i preseed. Config lives in [`http/user-data`](./http/user-data) + empty [`http/meta-data`](./http/meta-data).
2. **Boot path** — `/casper/vmlinuz` + `/casper/initrd` (live-server image), hand-loaded from GRUB via `boot_command`.
3. **Unattended-upgrades origin** — `${distro_id}:${distro_codename}-security` pattern (Ubuntu), set in [`ansible/roles/ubuntu_base/tasks/main.yml`](./ansible/roles/ubuntu_base/tasks/main.yml).

Everything else (`en*→nic0` rename, nftables baseline, chrony client at `192.168.70.1`, node_exporter on `:9100`, hardened sshd, SSH host-key regen drop-in, owner pubkey) is behaviourally identical to `deb13`. Phase 0.B.3 step 2 extracts those into `packer/_shared/ansible/roles/`.

Full design + runbook: [`../../docs/ubuntu24.md`](../../docs/ubuntu24.md).

## Directory layout

```
ubuntu24/
├── ubuntu24.pkr.hcl              # vmware-iso + ansible-local
├── variables.pkr.hcl
├── http/
│   ├── user-data                 # Subiquity autoinstall (#cloud-config)
│   └── meta-data                 # empty (required by NoCloud)
├── files/
│   ├── chrony.conf               # client; 192.168.70.1 prefer + ntp.ubuntu.com fallback
│   └── nftables.conf             # deny-in + SSH/9100 from VMnet11 (byte-identical to deb13)
└── ansible/
    ├── playbook.yml
    └── roles/ubuntu_base/
        ├── defaults/main.yml
        ├── handlers/main.yml
        ├── tasks/main.yml        # baseline + Ubuntu-specific tweaks
        └── files/nexusadmin.pub  # owner pubkey
```

## Quick reference

```powershell
make ubuntu24                     # ~10-12 min — builds template at H:/VMS/NexusPlatform/_templates/ubuntu24/
make ubuntu24-smoke               # ~10 sec — instantiates via terraform/modules/vm/
make ubuntu24-smoke-destroy       # tears down the smoke VM
```

## Ubuntu-specific extras (not in deb13)

- **`cloud-init network: disabled`** dropped at `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` so cloud-init doesn't regenerate netplan configs that race with our systemd-networkd `.link`/`.network` files.
- **`/etc/netplan/50-cloud-init.yaml` removed** — the installer ships this pointing at `ens*`; leaving it active would conflict with our DHCP-on-nic0 setup.
- **MOTD hygiene** — Ubuntu's dynamic `/etc/update-motd.d/*` scripts (Landscape ads, ESM nag, release-upgrade prompts) are disabled so SSH logins show only `/etc/motd`.

## Exit gate (step 1)

`make ubuntu24` produces `H:\VMS\NexusPlatform\_templates\ubuntu24\ubuntu24.vmx`; `make ubuntu24-smoke` boots a clone that:

1. renames its NIC to `nic0`,
2. takes a DHCP lease from `nexus-gateway` (range `192.168.70.200-.250`),
3. accepts SSH from VMnet11,
4. exposes `prometheus-node-exporter` on `:9100` (VMnet11-scoped),
5. syncs time from `192.168.70.1` via chrony.

Same exit criteria as deb13. Verification commands: [`docs/ubuntu24.md`](../../docs/ubuntu24.md).
