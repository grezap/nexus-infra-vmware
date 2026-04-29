# packer/vault

NexusPlatform **Vault cluster node template** (Phase 0.D.1). Three clones of this template form a 3-node Raft cluster (`vault-1`, `vault-2`, `vault-3`) on the foundation tier.

## Canon mapping

| Choice | Source |
|---|---|
| OS = Debian 13 | `nexus-platform-plan/docs/infra/vms.yaml` lines 55-57 |
| 2 vCPU per node | `vms.yaml` lines 55-57 |
| 40 GB disk per node | `vms.yaml` lines 55-57 |
| Dual-NIC (VMnet11 service + VMnet10 backplane) | `vms.yaml` lines 55-57 + `MASTER-PLAN.md` line 188 |
| Integrated Raft storage | `architecture.md` line 122 |
| Vault binary version | `var.vault_version` (default = latest stable as of build date; pinnable for upgrades) |

**Approved deviation from canon:** RAM = 2 GB (canon `vms.yaml` says 4 GB). Approved 2026-04-29 per `memory/feedback_prefer_less_memory.md`; vms.yaml will be updated post-0.D.1 to match observed-sufficient sizing.

## What gets baked into the template

| Layer | What | Where |
|---|---|---|
| OS install | Debian 13 netinst via preseed | `http/preseed.cfg` |
| Shared baseline | nexus_identity, nexus_network, nexus_firewall, nexus_observability | `../_shared/ansible/roles/` |
| Vault tail | `vault_node` role: binary install, systemd units, firstboot script, config template | `ansible/roles/vault_node/` |
| Firewall | Allow 8200/tcp from VMnet11 (clients), 8200+8201/tcp from VMnet10 (raft peers), plus standard SSH/9100 | `files/nftables.conf` |

## What's deferred to first-boot (per-clone)

`vault-firstboot.service` runs once per clone (idempotent via `/var/lib/vault-firstboot-done` marker):

1. Maps `/etc/hostname` → canonical VMnet10 IP (vault-1=.121, vault-2=.122, vault-3=.123)
2. Identifies the secondary NIC by MAC, renames it to `nic1`, assigns the static IP
3. Generates a fresh self-signed TLS cert with the clone's actual hostname + IPs in SAN
4. Renders `/etc/vault.d/vault.hcl` from `vault.hcl.tpl`, substituting `@HOSTNAME@`, `@VMNET11_IP@`, `@VMNET10_IP@`
5. Marks complete; `vault.service` (which has `After=vault-firstboot.service`) starts

## What happens at terraform apply time

`terraform/envs/security/role-overlay-vault-cluster.tf` orchestrates cluster bring-up after the three clones have booted (their vault.service is up but uninitialized + sealed):

1. SSH echo probe to all three nodes
2. `vault operator init` on `vault-1` → write keys to `~/.nexus/vault-init.json` on the build host
3. Unseal `vault-1` with 3 of 5 keys
4. `vault operator raft join` from `vault-2` and `vault-3` to `vault-1`
5. Unseal `vault-2` and `vault-3` with the same 3 keys
6. Verify `vault operator raft list-peers` shows 3 peers (1 leader + 2 followers)
7. Mount KV-v2 at `nexus/`
8. Enable userpass + AppRole auth methods
9. Write a smoke secret at `nexus/smoke/canary` for the smoke gate to read

## Build

```powershell
cd packer\vault
packer init .
packer build .
```

Or via Makefile (Linux/WSL):
```bash
make vault
```

Output: `H:\VMS\NexusPlatform\_templates\vault\vault.vmx`. ~10-15 min wall-clock on the build host (preseed install + Ansible roles + Vault binary download).

## Smoke (after `terraform/envs/security/` is applied)

```powershell
pwsh -NoProfile -File scripts\smoke-0.D.1.ps1
```

See `docs/handbook.md` §2 for the full Phase 0.D.1 reference.

## Files

| Path | Purpose |
|---|---|
| `vault.pkr.hcl` | Packer source + build blocks (mirrors `deb13.pkr.hcl` shape) |
| `variables.pkr.hcl` | Tunables incl. `var.vault_version` |
| `http/preseed.cfg` | Non-interactive Debian install |
| `files/nftables.conf` | Firewall ruleset (Vault ports added on top of deb13 baseline) |
| `files/chrony.conf` | Time sync (same as deb13) |
| `ansible/playbook.yml` | Runs the four shared roles + `vault_node` |
| `ansible/ansible.cfg` | `roles_path` for shared-role lookup at lint time |
| `ansible/roles/vault_node/tasks/main.yml` | Vault binary download + verify + install; systemd units; capabilities |
| `ansible/roles/vault_node/templates/vault.hcl.j2` | Vault config template (rendered by firstboot) |
| `ansible/roles/vault_node/templates/vault.service.j2` | systemd unit |
| `ansible/roles/vault_node/templates/vault-firstboot.service.j2` | First-boot oneshot unit |
| `ansible/roles/vault_node/files/vault-firstboot.sh` | First-boot logic (NIC config + TLS cert + render vault.hcl) |
