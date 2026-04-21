# terraform/modules/vm — reusable VM module (Phase 0.C)

**Status:** stub.

Consumed by `terraform/envs/{foundation,data,ml,saas,microservices,demo-minimal}` to instantiate VMs from any Packer-built template with:

- N NICs, each mapped to a named VMnet with a pinned MAC
- CPU / RAM / disk overrides
- Optional extra disks (for Kafka brokers, StarRocks BE, ClickHouse, etc.)
- Post-create Ansible hook pointing at an environment-specific inventory
- Tagging via vmx annotation for fleet-wide queries

Once this module is written, `scripts/configure-gateway-nics.ps1` and the null_resource pattern in `terraform/gateway/main.tf` collapse into a clean `module "nexus_gateway" { source = "../modules/vm" ... }` call. The gateway-specific logic stays in the module's per-role inputs.
