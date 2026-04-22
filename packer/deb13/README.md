# packer/deb13 — Debian 13 generic base template (Phase 0.B.2)

**Status:** ✅ shipped. Built + smoke-verified end-to-end (template → `modules/vm/` clone → DHCP lease → SSH + node_exporter reachable on VMnet11).

The parent image for ~60 of the 65 lab VMs. Each role-specific VM (Vault, Postgres, Kafka, Mongo, Redis, ClickHouse, StarRocks, MinIO, Swarm nodes, Spark workers, …) clones this template via `terraform/modules/vm/` and overlays its own Ansible.

Full design, build + smoke runbook, verification checklist, and design-decision rationale: [`../../docs/deb13.md`](../../docs/deb13.md).

## Directory layout

```
deb13/
├── deb13.pkr.hcl                 # vmware-iso + ansible-local; single NIC (NAT) at build
├── variables.pkr.hcl
├── http/
│   └── preseed.cfg               # Debian 13 netinst preseed — no router pkgs
├── files/
│   ├── chrony.conf               # client, 192.168.70.1 prefer + public-pool fallback
│   └── nftables.conf             # deny-inbound baseline, allow SSH+9100 from VMnet11
└── ansible/
    ├── playbook.yml
    └── roles/debian_base/
        ├── defaults/main.yml
        ├── handlers/main.yml
        ├── tasks/main.yml        # the shared baseline — see docs/deb13.md
        └── files/nexusadmin.pub  # owner pubkey; baked into clone's authorized_keys
```

## Quick reference

```powershell
make deb13                       # ~7–8 min — builds template at H:/VMS/NexusPlatform/_templates/deb13/
make deb13-smoke                 # ~10 sec — instantiates via terraform/modules/vm/
make deb13-smoke-destroy         # tears down the smoke VM
```

## What the base role ships (`debian_base`)

- `nexusadmin` sudoer + baked-in owner pubkey (key-auth on day one for every clone)
- `systemd-networkd` with MAC-agnostic NIC rename: `OriginalName=en*` → `nic0`, DHCP from `nexus-gateway`
- `nftables` baseline (deny-in, allow SSH + `:9100` from `192.168.70.0/24` only)
- `chrony` client pointed at `192.168.70.1` with public NTP pool fallback
- `prometheus-node-exporter` on `:9100`
- Hardened `sshd` via `sshd_config.d/10-nexus-hardening.conf` drop-in
- Unattended upgrades limited to the `Debian-Security` origin
- SSH host-key regeneration on first boot via `ssh.service.d/10-regenerate-host-keys.conf` drop-in (`ExecStartPre=` cleared then re-ordered so `ssh-keygen -A` runs before `sshd -t`)

## What it deliberately does **not** ship

- No dnsmasq, no DHCP server, no `ip_forward`, no masquerade — that's `nexus-gateway`'s job.
- No OpenTelemetry Collector — architecture.md defers it to the DRY refactor at Phase 0.B.3 when the second base-image (`ubuntu24`) arrives and reveals the right shared-role shape.
- No database/app runtime/TLS tooling — those are role overlays applied per-VM.

## Exit gate

`make deb13` produces `H:\VMS\NexusPlatform\_templates\deb13\deb13.vmx`; `make deb13-smoke` boots a clone that:

1. renames its NIC to `nic0`,
2. takes a DHCP lease from `nexus-gateway` (range `192.168.70.200-.250`),
3. accepts SSH from VMnet11,
4. exposes `prometheus-node-exporter` on `:9100` (VMnet11-scoped),
5. syncs time from `192.168.70.1` via chrony.

All five verified — see [`docs/deb13.md`](../../docs/deb13.md) for the exact verification commands.
