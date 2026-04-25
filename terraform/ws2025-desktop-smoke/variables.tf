variable "template_vmx_path" {
  description = "Absolute path to the Packer-built ws2025-desktop template .vmx."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/ws2025-desktop/ws2025-desktop.vmx"
}

variable "vm_output_dir" {
  description = "Directory where the smoke-test clone is placed."
  type        = string
  default     = "H:/VMS/NexusPlatform/90-smoke/ws2025-desktop-smoke"
}

variable "mac_address" {
  description = "Static MAC for the smoke-test VM's single NIC. Must be in the smoke-test range 00:50:56:3F:00:20-2F."
  type        = string
  default     = "00:50:56:3F:00:23"
}
