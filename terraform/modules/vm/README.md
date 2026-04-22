# terraform/modules/vm

Reusable VMware Workstation VM module for NexusPlatform lab VMs. **Implemented in Phase 0.B.2** — consumed first by `terraform/deb13-smoke/` to verify the deb13 template, later by `terraform/envs/{foundation,data,ml,…}` as each env lands.

Instantiates a Packer-built template as a running VM with a single pinned-MAC NIC on a caller-chosen VMnet. Drives `vmrun.exe` through `null_resource` + `local-exec` — no `vmrest` daemon or third-party provider required.

## Why this module exists

The `terraform/gateway/` module is hand-rolled for nexus-gateway's 3-NIC topology (bridged + VMnet11 + VMnet10). Every other lab VM has a simpler shape: one NIC on VMnet11, one MAC from the user range, clone-and-go. This module is that generic case. Future multi-NIC VMs (core-services tier) will get their own per-env resource blocks or a `count`/`for_each` wrapper on top of this module — we'll know the right shape once we have a second multi-NIC case.

## Inputs

| Variable            | Required | Default                                                  | Notes |
|---------------------|----------|----------------------------------------------------------|-------|
| `vm_name`           | yes      | —                                                        | Unique. Used as `.vmx` basename and `vmrun -cloneName`. |
| `template_vmx_path` | yes      | —                                                        | Absolute path to the Packer-built `.vmx` (e.g. the deb13 template). |
| `vm_output_dir`     | yes      | —                                                        | Where the clone lands. Created by `vmrun clone`. |
| `vnet`              | no       | `VMnet11`                                                | VMware network name. Case-insensitive. Built-ins: `bridged`, `nat`, `hostonly`. |
| `mac_address`       | yes      | —                                                        | `00:50:56:XX:YY:ZZ` with `XX` in `0x00..0x3F`. Regex-validated. |
| `cpus`              | no       | `2`                                                      | Reserved — not yet applied at runtime (Packer template value inherited). |
| `memory_mb`         | no       | `1024`                                                   | Reserved — not yet applied. |
| `vmrun_path`        | no       | `C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe` | Override if Workstation is installed elsewhere. |

## Outputs

| Output         | Value |
|----------------|-------|
| `vm_path`      | `${vm_output_dir}/${vm_name}.vmx` |
| `mac_address`  | Pass-through of the input MAC.     |
| `vm_name`      | Pass-through of the input name.    |

## Usage

```hcl
module "my_vm" {
  source = "../modules/vm"

  vm_name           = "my-postgres"
  template_vmx_path = "H:/VMS/NexusPlatform/_templates/deb13/deb13.vmx"
  vm_output_dir     = "H:/VMS/NexusPlatform/20-data/my-postgres"
  mac_address       = "00:50:56:3F:00:30"
  # vnet defaults to VMnet11
}

output "postgres_mac" { value = module.my_vm.mac_address }
```

The VM boots, DHCPs from `nexus-gateway`'s dnsmasq (typically gets an IP in `192.168.70.200-.250`), and is reachable via SSH from the host at whatever DHCP address it lands on. If you want a pinned IP, declare a static lease in `nexus-gateway`'s dnsmasq config (the `addn-hosts` mechanism — see `docs/nexus-gateway.md`).

## MAC allocation convention

Reserve MAC ranges per tier so you don't collide:

| Range                   | Purpose                                     |
|-------------------------|---------------------------------------------|
| `00:50:56:3F:00:10-1F`  | Edge tier (gateway has `:10`, `:11`, `:12`). |
| `00:50:56:3F:00:20-2F`  | Smoke-test / scratch VMs.                   |
| `00:50:56:3F:00:30-3F`  | Data-tier VMs (Postgres, Mongo, …).         |
| `00:50:56:3F:00:40-4F`  | Core services (Vault, Consul, …).           |
| `00:50:56:3F:00:50-5F`  | Apps tier.                                  |
| `00:50:56:3F:00:60-FF`  | Reserved for future tiers.                  |

These are conventions, not enforced. Document each allocation in the calling module's `variables.tf`.

## Limitations

- **Single NIC only.** Multi-NIC VMs hand-roll their own `null_resource` chain (see `terraform/gateway/`).
- **`cpus` and `memory_mb` inputs are not yet applied.** Packer's template values are inherited. Future improvement: edit the cloned `.vmx` in `configure_nic` (it already rewrites ethernet entries; same pattern extends to `numvcpus` + `memsize`).
- **Destroy is hard-kill** (`vmrun stop <vmx> hard`). For graceful shutdown, add a destroy provisioner running `vmrun stop <vmx> soft` ahead of `power_on`.
