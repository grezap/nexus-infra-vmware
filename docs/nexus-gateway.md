# nexus-gateway — design + runbook

**VM #0 of the NexusPlatform 66-VM fleet.** The lab edge router: provides internet egress for VMnet11, DHCP+DNS for the lab, and NTP for the whole fleet. Must be built and running before any other Linux VM (because every other VM pulls apt packages through it).

## Why this VM exists

VMware Workstation Pro on Windows allows exactly **one NAT network per host** (platform constraint). On host `10.0.70.101` that slot is held by `VMnet8` used by other tenants. `VMnet11` is therefore Host-Only; without a gateway, lab VMs have no path to the internet.

Options rejected:

| Option | Rejected because |
|---|---|
| Windows RRAS/ICS on the host | Host-dependent, not versioned, breaks on Windows Updates, doesn't match canon's "infra is code" discipline |
| Share VMnet8 subnet | Would collide with other tenants' 192.168.203.0/24 addressing |
| Give every VM a Bridged NIC | Pollutes physical LAN with 65 random DHCP clients; privacy + firewall problems |

A single purpose-built Linux router is the senior-engineer answer: it's 512 MB, 4 GB of disk, versioned Packer HCL, deterministic Ansible, restartable in 10 seconds, and matches how real on-prem labs work.

## Topology

```
                Internet
                   │
                   │ (home router / ISP)
                   │
┌──────────────────┴──────────────────┐
│  Physical LAN  (e.g. 10.0.70.0/24)  │
└──────────────────┬──────────────────┘
                   │ NIC0 bridged
                   │ DHCP from home router
                   │
          ┌────────▼────────┐
          │                 │
          │  nexus-gateway  │
          │   Debian 13     │
          │                 │
          │  nftables       │ nftables: masquerade 192.168.70.0/24 → NIC0
          │  dnsmasq        │ dnsmasq:  DHCP .200-.250 + DNS forwarder
          │  chrony         │ chrony:   NTP for lab
          │                 │
          └────┬────────┬───┘
               │        │
    NIC1 VMnet11│        │ NIC2 VMnet10
    192.168.70.1        192.168.10.1
    (lab gateway,       (backplane visibility,
     DHCP/DNS/NTP       ICMP only — explicitly
     server)             NOT routed to NIC0)
               │                │
    ┌──────────▼────────┐  ┌────▼──────────┐
    │  lab VMs on       │  │  lab VMs on   │
    │  192.168.70.0/24  │  │  192.168.10   │
    │  (mgmt + apps)    │  │  (backplane,  │
    │                   │  │   isolated)   │
    └───────────────────┘  └───────────────┘
```

Firewall rules enforce: VMnet10 never reaches the internet; only VMnet11 is masqueraded.

## Build + deploy

Prerequisites:
- Packer 1.11+, Terraform 1.9+ on the Windows host
- VMware Workstation Pro 17.6+ installed (the `vmrun.exe` CLI ships with it — no separate daemon needed)
- Phase 0.A complete (VMnet10 + VMnet11 created, host adapters bound)

```powershell
# 1. Build the Packer template (~7 min — downloads Debian 13 netinst ISO, preseed, Ansible)
cd "F:\_CODING_\…\nexus-infra-vmware"
Push-Location packer\nexus-gateway
packer build -var "output_directory=H:/VMS/NexusPlatform/_templates/nexus-gateway" nexus-gateway.pkr.hcl
Pop-Location
# Template lands at: H:\VMS\NexusPlatform\_templates\nexus-gateway\nexus-gateway.vmx

# 2. Deploy the running instance (clones template → rewrites NICs → powers on)
Push-Location terraform\gateway; terraform apply -auto-approve; Pop-Location
# Instance lands at: H:\VMS\NexusPlatform\00-edge\nexus-gateway\nexus-gateway.vmx

# 3. Verify
Test-NetConnection 192.168.70.1 -Port 53
Test-NetConnection 192.168.70.1 -Port 22
nslookup one.one.one.one 192.168.70.1
```

> Linux/WSL/CI users can substitute the equivalent `make gateway` / `make gateway-apply` Makefile targets. GNU make is not installed on the canonical Windows build host -- the pwsh-native commands above are canonical there per [`memory/feedback_build_host_pwsh_native.md`](../memory/feedback_build_host_pwsh_native.md).

Expected result: 53 and 22 return `TcpTestSucceeded : True`; `nslookup` resolves `1.1.1.1` via the gateway.

**No `terraform.tfvars` needed** — defaults in `terraform/gateway/variables.tf` (template path, MACs, output dir) are correct for host `10.0.70.101`. Only override if paths/MACs change.

**To see the VM in Workstation's sidebar** (optional — purely cosmetic, Terraform doesn't care):

> File → Open… → `H:\VMS\NexusPlatform\00-edge\nexus-gateway\nexus-gateway.vmx`

Workstation's library is a per-user inventory (`%APPDATA%\VMware\inventory.vmls`) separate from the filesystem. `vmrun start` powers VMs on but doesn't register them in that inventory.

## Verification checklist

Run these from the Windows host after `terraform apply`:

```powershell
# Port reachability
Test-NetConnection 192.168.70.1 -Port 53   # dnsmasq DNS
Test-NetConnection 192.168.70.1 -Port 67   # dnsmasq DHCP (UDP — see note)
Test-NetConnection 192.168.70.1 -Port 123  # chrony NTP (UDP)
Test-NetConnection 192.168.70.1 -Port 9100 # node_exporter

# DNS forwarding works
nslookup debian.org     192.168.70.1
nslookup nexus.local    192.168.70.1
nslookup 192.168.70.1   192.168.70.1

# SSH in (build credentials inherited from Packer template; rotated in Phase 0.D).
# Assumes handbook §0.4 SSH client setup; otherwise prepend `-i $HOME\.ssh\nexus_gateway_ed25519`.
ssh nexusadmin@192.168.70.1
```

Inside the VM:

```bash
# Ruleset loaded
sudo nft list ruleset | head

# Services healthy
systemctl is-active nftables dnsmasq chrony prometheus-node-exporter

# Sources
chronyc sources -v

# Counters
sudo nft list counter

# Internet reachable via NIC0
curl -I https://cdimage.debian.org | head -1
```

## Operational notes

- **Logs**: everything goes to journald. `journalctl -u dnsmasq` / `-u chrony` / `-u nftables`.
- **Monitoring**: Prometheus (obs-metrics VM, Phase 0.I) scrapes `192.168.70.1:9100`. Blackbox probe tests 53, 123, and 192.168.70.1 ping.
- **Backup**: nightly VMware snapshot via `nexus-cli infrastructure snapshot nexus-gateway`. Cold-standby .vmx kept at `D:\VMS\NexusPlatform\00-edge\nexus-gateway.backup/`.
- **Upgrades**: `unattended-upgrades` handles security patches. Full Debian version upgrades are manual, tested in isolation first.
- **SPOF mitigation**: ADR-0142 (planned) covers active-standby pattern with a second gateway VM on the host and keepalived VRRP carrying the 192.168.70.1 VIP.

## Known limits (v0.1.0)

- **Single point of failure.** If nexus-gateway is down, the lab loses internet. Acceptable for a portfolio lab; Tier-1 HA rework in ADR-0142.
- **No WireGuard / remote access.** External access to the lab is via the Windows host itself. Phase 0.E adds a bastion pattern on VMnet11.
- **SSH key rotation** is deferred to Phase 0.D (requires Vault to be up — chicken-and-egg resolved by build-time password).
- **No Terraform provider for Workstation.** The module drives `vmrun.exe` through `null_resource` + `local-exec`. See "Known issues" below.

## Rebuild procedure

If nexus-gateway becomes corrupted:

```powershell
Push-Location terraform\gateway; terraform destroy -auto-approve; Pop-Location

Push-Location packer\nexus-gateway
packer build -var "output_directory=H:/VMS/NexusPlatform/_templates/nexus-gateway" nexus-gateway.pkr.hcl
Pop-Location                                                                            # rebuild template

Push-Location terraform\gateway; terraform apply -auto-approve; Pop-Location            # redeploy
```

Total recovery time: ~6 minutes on NVMe.

## Known issues & design decisions

### Why no `elsudano/vmworkstation` Terraform provider

Phase 0.B.1 originally tried `elsudano/vmworkstation` v2.0.1. Three blocker bugs against `vmrest` 17.6.x:

1. **`path` attribute is ignored.** Provider always clones into `%USERPROFILE%\Documents\Virtual Machines\<name>\` then reports that path back, which fails Terraform's post-apply consistency check when you asked for a different destination.
2. **Redundant NIC parameter** ([elsudano/terraform-provider-vmworkstation#28](https://github.com/elsudano/terraform-provider-vmworkstation/issues/28)): SDK's clone-then-reconstruct-NIC sequence sends `vmnet8` alongside `connectionType=nat`, which `vmrest` rejects.
3. **SDK panic** when the template `.vmx` has zero ethernet entries — `CreateVM` unconditionally dereferences `NICS[0]`.

Resolution: drive `vmrun.exe` (the CLI bundled with Workstation) directly from Terraform `null_resource` + `local-exec`. Gives us full control of the clone destination, avoids `vmrest` PUT bugs entirely, and matches how the Packer build already interacts with Workstation. `vmrest.exe` is **not** required at any point — the CLI is sufficient.

### NIC renaming must match by MAC, not PCI path

The Ansible role deploys three `systemd` `.link` files under `/etc/systemd/network/` that rename `ensXXX` → `nic0/nic1/nic2` at boot. Early versions matched by `Path=pci-0000:02:01.0` etc., which broke in practice: Workstation's clone-then-add-NIC flow assigns `pciSlotNumber` values (typically 160/192/224) that produce different `Path=` strings than the original template's single-NIC layout.

Fix (current): `[Match] MACAddress=…` keyed on the MACs pinned by `scripts/configure-gateway-nics.ps1` before first boot. MACs come from `terraform/gateway/variables.tf` defaults and are duplicated into the Ansible role (`tasks/main.yml`). **If you override MACs in `terraform.tfvars`, rebuild the Packer template with matching `-var mac_nicN=…` arguments** or the rename won't fire and dnsmasq won't bind.

### dnsmasq build-time gotcha

`files/dnsmasq.conf` uses `interface=nic1` `bind-interfaces`. At Packer build time nic1 doesn't exist (only the single NAT NIC), so the role **enables but does not start** dnsmasq. It comes up on the first post-clone boot when the real NIC topology is in place. The handler also uses `state: stopped` rather than `restarted` for the same reason.

### Troubleshooting: ping 192.168.70.1 fails after `terraform apply`

Give it 20–30s for Debian cold boot. If still failing, open the VM in Workstation GUI (see "Build + deploy" step 3 note) and check from the console:

```bash
ip -br link                                                       # nic0/nic1/nic2, not ensXXX
ip -br addr                                                       # 192.168.70.1/24 on nic1
systemctl status systemd-networkd dnsmasq nftables chrony
journalctl -u systemd-networkd --no-pager | tail -30
sudo nft list ruleset | head -40
```

Common failure modes:

| Symptom | Likely cause |
|---|---|
| `ensXXX` not renamed | `.link` MAC match failed — check `.vmx` MACs vs `/etc/systemd/network/1[012]-nicN.link` |
| nic1/nic2 renamed but DOWN | `.network` file missing or wrong `Name=` match — compare with `tasks/main.yml` |
| DNS (:53) closed, SSH (:22) open | dnsmasq bind failure — check `journalctl -u dnsmasq` for "interface not found" |
| Host routing via wrong adapter | `Get-NetIPAddress -InterfaceAlias 'VMware Network Adapter VMnet11'` — should be `192.168.70.254` |
