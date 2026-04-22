variable "template_vmx_path" {
  description = "Absolute path to the Packer-built deb13 template .vmx."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/deb13/deb13.vmx"
}

variable "vm_output_dir" {
  description = "Directory where the smoke-test clone is placed."
  type        = string
  default     = "H:/VMS/NexusPlatform/90-smoke/deb13-smoke"
}

variable "mac_address" {
  description = "Static MAC for the smoke-test VM's single NIC. Must be in the smoke-test range 00:50:56:3F:00:20-2F."
  type        = string
  default     = "00:50:56:3F:00:20"
}
