# terraform/gateway/example.tfvars
#
# Copy to terraform.tfvars (gitignored) and edit ONLY if defaults in
# variables.tf are wrong for your host. For host 10.0.70.101 the defaults
# are already correct — you do not need a terraform.tfvars at all.

# Absolute path to the Packer-built template .vmx. Must exist before apply.
# template_vmx_path = "H:/VMS/NexusPlatform/_templates/nexus-gateway/nexus-gateway.vmx"

# Where the running VM clone will be placed. Directory will be created.
# vm_output_dir = "H:/VMS/NexusPlatform/00-edge/nexus-gateway"

# Pinned MACs for stable systemd interface naming.
# - 00:50:56 is VMware's OUI.
# - Fourth byte must be 0x00-0x3F for user-assignable statics.
# - If you change these, rebuild the Packer template with matching
#   `packer build -var mac_nicN=...` (the Ansible role bakes them into
#   /etc/systemd/network/1N-nicN.link for MAC-based NIC renaming).
# mac_nic0 = "00:50:56:3F:00:10" # bridged  — physical LAN egress
# mac_nic1 = "00:50:56:3F:00:11" # VMnet11  — 192.168.70.1 lab gateway
# mac_nic2 = "00:50:56:3F:00:12" # VMnet10  — 192.168.10.1 backplane
