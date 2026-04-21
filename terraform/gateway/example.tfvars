# terraform/gateway/example.tfvars
# Copy to terraform.tfvars (gitignored) and fill in.

# VMware Workstation REST API credentials.
# Enable the daemon with:
#   & "C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe" -C
# Then set credentials, and run:
#   & "C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe"
vmware_workstation_user     = "nexusadmin"
vmware_workstation_password = "change-me"
vmware_workstation_api_url  = "http://127.0.0.1:8697/api"

# Packer-built template ID — visible in `vmrest` GET /vms or via the API.
# Example: 11CED111F0FF1CA11111
template_id = "REPLACE_WITH_TEMPLATE_ID"

# Where to place the running VM
vm_output_dir = "H:/VMS/NexusPlatform/00-edge/nexus-gateway"

# MACs are pinned for stable systemd NIC naming. 00:50:56 is VMware's OUI;
# fourth byte must be 0x00-0x3F for user-assignable static MACs.
mac_nic0 = "00:50:56:3F:00:10"  # bridged
mac_nic1 = "00:50:56:3F:00:11"  # VMnet11
mac_nic2 = "00:50:56:3F:00:12"  # VMnet10
