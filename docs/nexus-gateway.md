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
- VMware Workstation Pro running
- Phase 0.A complete (VMnet10 + VMnet11 created, host adapters bound)

```powershell
# 1. Build the Packer template (~5 min — downloads Debian 13 netinst ISO + runs preseed + Ansible)
cd F:\_CODING_\...\nexus-infra-vmware
make gateway

# 2. Enable VMware Workstation REST API daemon (one-time)
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe' -C
# Set credentials when prompted. Then run in a separate window:
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'

# 3. Copy the example tfvars and fill in template_id + creds
cd terraform/gateway
Copy-Item example.tfvars terraform.tfvars
notepad terraform.tfvars

# 4. Apply
terraform init
terraform apply

# 5. Verify
Test-NetConnection 192.168.70.1 -Port 53
Test-NetConnection 192.168.70.1 -Port 9100
nslookup one.one.one.one 192.168.70.1
```

Expected result: `192.168.70.1` responds on DNS/53 and node_exporter/9100; `nslookup` resolves `1.1.1.1`.

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

# SSH in (build credentials — rotated in Phase 0.D)
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
- **MAC pinning by script** (vmx edit) rather than via the Terraform provider. Pattern will move into the reusable `terraform/modules/vm/` module once the provider gains full NIC support.

## Rebuild procedure

If nexus-gateway becomes corrupted:

```powershell
cd terraform\gateway
terraform destroy -auto-approve

cd ..\..
make gateway          # rebuild template
make gateway-apply    # redeploy
```

Total recovery time: ~6 minutes on NVMe.
