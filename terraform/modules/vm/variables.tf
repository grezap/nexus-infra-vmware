variable "vm_name" {
  description = "Unique VM name. Used as the cloned .vmx basename + vmrun -cloneName."
  type        = string
}

variable "template_vmx_path" {
  description = "Absolute path to the Packer-built template .vmx (e.g. H:/VMS/NexusPlatform/_templates/deb13/deb13.vmx)."
  type        = string
}

variable "vm_output_dir" {
  description = "Directory where the running VM instance's .vmx + disks live. Will be created by vmrun clone."
  type        = string
}

variable "vnet" {
  description = "VMware network name (e.g. VMnet11 for the lab, VMnet10 for backplane). Case-insensitive. Built-in values: bridged, nat, hostonly."
  type        = string
  default     = "VMnet11"
}

variable "mac_address" {
  description = "Static MAC for the VM's single NIC. Must be 00:50:56:XX:YY:ZZ with fourth byte in 0x00-0x3F (VMware user-managed range)."
  type        = string
  validation {
    condition     = can(regex("^00:50:56:[0-3][0-9A-Fa-f]:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$", var.mac_address))
    error_message = "MAC must match 00:50:56:XX:YY:ZZ where XX is 00-3F."
  }
}

variable "cpus" {
  description = "Number of vCPUs for the running instance. Not currently applied (Packer template value inherited); reserved for future vmrun-based resize."
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM for the running instance (MB). Not currently applied; reserved for future resize step."
  type        = number
  default     = 1024
}

variable "vmrun_path" {
  description = "Absolute path to vmrun.exe."
  type        = string
  default     = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
}
