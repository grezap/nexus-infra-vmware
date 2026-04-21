# packer/deb13 — Debian 13 generic base template (Phase 0.B.2)

**Status:** stub — implementation scheduled for Phase 0.B.2 after `nexus-gateway` is verified operational.

## What this template produces

A minimal Debian 13 VM image used as the base for the majority of the 65 lab VMs (Vault, Postgres, Kafka, Mongo, Redis, ClickHouse, StarRocks, Swarm workers, Spark, MinIO, etc.).

## Required contents (to be added)

```
deb13/
├── deb13.pkr.hcl              # vmware-iso + ansible-local, single NIC on VMnet11
├── variables.pkr.hcl
├── http/preseed.cfg           # like nexus-gateway/http/preseed.cfg but no router packages
├── files/                     # minimal — ca-certs, chrony client config pointing at 192.168.70.1
└── ansible/
    ├── playbook.yml
    └── roles/
        └── debian_base/
            ├── tasks/main.yml
            ├── handlers/main.yml
            └── defaults/main.yml
```

## Canonical inputs for this template

- **Base role:** `debian_base` — creates the `nexusadmin` user, installs OTel Collector (node), prometheus-node-exporter, chrony client pointed at `192.168.70.1`, nftables baseline (deny-all-inbound + allow SSH from VMnet11), Vault agent stub, Debian unattended-security.
- **Shared with other templates:** the OTel + node_exporter + chrony-client tasks move into `packer/_shared/ansible/roles/nexus_observability/` once this template is written (DRY refactor at Phase 0.B.3).

## Exit gate

`packer build` produces a clean `.vmx` at `H:\VMS\NexusPlatform\_templates\deb13\` that Terraform `modules/vm/` (Phase 0.C) can instantiate, and a fresh clone can `sudo apt update` in under 5 seconds (via nexus-gateway).
