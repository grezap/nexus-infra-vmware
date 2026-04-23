# Architecture — nexus-infra-vmware

## Goals

1. **Reproducibility** — every VM in the 66-VM fleet is built from a Packer HCL template committed to git. A `terraform apply` on a fresh Windows host re-creates the entire lab end-to-end.
2. **Deterministic provisioning** — same inputs → byte-identical output. Pinned ISO URLs + checksums, pinned Packer/Terraform/Ansible versions, pinned MACs.
3. **Separation of concerns** — Packer builds images, Terraform places VMs, Ansible configures guest OS. No overlap.
4. **Testable in CI** — `packer validate`, `terraform validate`, `ansible-lint` run on every push (no VMware host needed for static validation).

## Toolchain rationale

| Layer | Tool | Chosen because | Rejected alternatives |
|---|---|---|---|
| Image build | Packer + `hashicorp/vmware` | Native `.vmx` output; proven with Workstation; widest community | Hashicorp Vagrant (heavier, adds dead weight); bespoke PowerShell scripts (not versioned, not testable) |
| Provisioning | Terraform + `elsudano/vmworkstation` + vmrun fallback | Declarative state; closest-to-vSphere-workflow; works with Workstation REST | `terraform-provider-vmware/vmware-desktop` (community, less active as of 2026); pure vmrun scripts (imperative, no state) |
| Guest config | Ansible via `ansible-local` provisioner in Packer | Idempotent; declarative roles; runs inside the VM (no SSH from build host needed) | Chef/Puppet (overkill); bare shell scripts (not idempotent) |
| Guest OS | Debian 13 minimal (gateway), later deb13/ubuntu24 generic | Small footprint; nftables native; LTS; matches senior-Linux conventions | Alpine (musl → .NET compat pain); CentOS Stream (EOL trajectory risk) |

## Build pipeline

```
                           ┌────────────────────────────┐
                           │ ISO: cdimage.debian.org    │
                           │ SHA256 pinned in HCL       │
                           └─────────────┬──────────────┘
                                         │
                                         ▼
 packer/nexus-gateway/nexus-gateway.pkr.hcl
         │
         │ 1. vmware-iso builder boots ISO
         │ 2. preseed.cfg (served via HTTP) automates install
         │ 3. Packer SSHs in after first boot
         │ 4. file provisioners stage nftables/dnsmasq/chrony configs
         │ 5. ansible-local runs nexus_gateway role
         │ 6. shutdown + VMX finalize
         │
         ▼
 Golden template: H:\VMS\NexusPlatform\_templates\nexus-gateway\*.vmx
         │
         │ terraform apply consumes template_id
         │
         ▼
 Running VM: H:\VMS\NexusPlatform\00-edge\nexus-gateway\*.vmx
         │
         │ scripts/configure-gateway-nics.ps1 rewrites NICs
         │ vmrun start
         │
         ▼
 nexus-gateway powered on, serving DHCP/DNS/NAT on VMnet11
```

## State + secrets

- **Terraform state** — local `.tfstate` for v0.1.x (single-user lab). Phase 0.E migrates to Consul KV backend once Consul is up.
- **Packer secrets** — none beyond the build-time SSH password, which is (a) hardcoded to a throwaway value in `variables.pkr.hcl`, (b) lives only during the build, (c) rotated to key-only auth in Phase 0.D once Vault is up.
- **Vault integration** — all post-v0.1 templates pull their root CA + SSH CA from Vault via Packer's `vault` function. For nexus-gateway itself (bootstrap VM, built before Vault exists), we ship a self-signed cert that gets replaced on first Ansible run after Vault comes online.

## Layering for future templates

Each subsequent template (`deb13`, `ubuntu24`, etc.) follows the same shape:

```
packer/<template>/
  <template>.pkr.hcl      # vmware-iso source + build block
  variables.pkr.hcl       # tunables
  http/preseed.cfg        # (or autounattend.xml for Windows)
  files/                  # static configs staged to /tmp
  ansible/
    playbook.yml
    roles/<role>/
      tasks/main.yml
      handlers/main.yml
      defaults/main.yml   # role inputs
```

Common Ansible logic is extracted into shared roles under `packer/_shared/ansible/roles/` once ≥2 templates need the same thing. The Phase 0.B.3 DRY pass (landed after `deb13` and `ubuntu24` both existed) split the common baseline into four generic roles:

| Shared role             | Responsibility                                                       |
|-------------------------|----------------------------------------------------------------------|
| `nexus_identity`        | Owner SSH pubkey → nexusadmin authorized_keys, sshd hardening drop-in, ssh.service ExecStartPre re-ordering so `ssh-keygen -A` runs before `sshd -t` on first boot |
| `nexus_network`         | systemd `.link` rename `en* → nic0`, systemd-networkd DHCP, chrony client pointed at 192.168.70.1 |
| `nexus_firewall`        | nftables baseline (deny-in; allow SSH + :9100 from VMnet11)          |
| `nexus_observability`   | prometheus-node-exporter on :9100. Reserves room for OTel Collector (Phase 0.I), filebeat/vector, hardware exporters — added here as they become shared. |

Per-template roles (`debian_base`, `ubuntu_base`, …) shrink to the OS-specific tail: distro-specific package lists, the `unattended-upgrades` origin pattern (`Debian-Security` vs `${distro_id}:${distro_codename}-security` + ESM), MOTD banner text, and (Ubuntu only) cloud-init network-config disable + `/etc/netplan/50-cloud-init.yaml` removal + `/etc/update-motd.d/*` chmod 0644. Each template's `ansible/playbook.yml` runs the four shared roles first, then its OS tail; Packer's `ansible-local` provisioner uploads each role via its `role_paths` list so they resolve by name without symlinks or vendored copies.

## Windows templates — deliberately parallel, not unified

The Linux `_shared/ansible/roles/nexus_*` are deeply Linux-specific (systemd units, nftables, systemd-networkd `.link`/`.network`, chrony). Windows has analogous *jobs* — local admin + SSH, NIC naming, firewall, time sync, metrics export — but every *implementation* is different (Windows Firewall cmdlets, W32Time, Rename-NetAdapter, windows_exporter MSI, OpenSSH-Server Windows Capability, WinRM-for-build / OpenSSH-for-runtime).

Rather than force-fit Ansible across the OS boundary (which would require build-host pywinrm + WSL or Python inside the Windows template — both painful), the Windows templates use native PowerShell provisioners with script names parallel to the Linux role names:

| Linux shared role      | Windows PowerShell parallel (ws2025-core/scripts/) |
|------------------------|----------------------------------------------------|
| `nexus_identity`       | `01-nexus-identity.ps1`                            |
| `nexus_network`        | `02-nexus-network.ps1`                             |
| `nexus_firewall`       | `03-nexus-firewall.ps1`                            |
| `nexus_observability`  | `04-nexus-observability.ps1`                       |

Same parallel naming is intentional — reading the two trees side-by-side makes the one-to-one correspondence obvious. DRY extraction into `packer/_shared/powershell/` (modules or a scripts/ dir) is deferred until the second Windows template (`ws2025-desktop`, Phase 0.B.5) gives us two concrete callers, matching the same two-call-sites principle the Linux extraction followed.

## Why vmrun/PowerShell for NIC config

The `elsudano/vmworkstation` provider v1.2.0 supports create/delete/start/stop but does not yet expose `ethernet*.connectionType` or `ethernet*.address`. Three options were weighed:

1. **Fork the provider and add the fields** — correct long-term, but delays Phase 0.B by weeks.
2. **Use `packer-plugin-virtualbox` + VBoxManage** — changes hypervisor entirely; rejected.
3. **Edit VMX post-clone via PowerShell** — pragmatic, idempotent, well-bounded. Chosen.

When the provider gains full NIC support, `scripts/configure-gateway-nics.ps1` becomes dead code and the null_resource disappears.

## Related ADRs (canonical, in nexus-platform-plan)

- ADR-0140 — Packer + Terraform + Ansible toolchain split
- ADR-0141 — vmware-desktop provider vs vSphere stub vs vmrun
- ADR-0142 — nexus-gateway HA pattern (planned; active-standby with keepalived VRRP 192.168.70.1 VIP)
- ADR-0143 — Golden image refresh cadence (monthly base, weekly security)

## Forward references

- **Phase 0.C** (Terraform env modules) — introduces `terraform/envs/{foundation,data,ml,saas,microservices,demo-minimal}` that compose multiple `modules/vm/` instances.
- **Phase 0.D** (Vault) — bootstraps a 3-node Vault Raft cluster; cert issuance moves to Vault PKI.
- **Phase 0.I** (Observability) — Prometheus on obs-metrics scrapes every VM's node_exporter, including nexus-gateway.
