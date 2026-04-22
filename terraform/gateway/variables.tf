variable "template_vmx_path" {
  description = "Absolute path to the Packer-built nexus-gateway template .vmx file."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/nexus-gateway/nexus-gateway.vmx"
}

variable "vm_output_dir" {
  description = "Directory where the running VM instance is placed (will be created by vmrun clone)."
  type        = string
  default     = "H:/VMS/NexusPlatform/00-edge/nexus-gateway"
}

variable "mac_nic0" {
  description = "MAC for NIC0 (Bridged — physical LAN egress)."
  type        = string
  default     = "00:50:56:3F:00:10"
}

variable "mac_nic1" {
  description = "MAC for NIC1 (VMnet11 — 192.168.70.1 lab gateway)."
  type        = string
  default     = "00:50:56:3F:00:11"
}

variable "mac_nic2" {
  description = "MAC for NIC2 (VMnet10 — 192.168.10.1 backplane)."
  type        = string
  default     = "00:50:56:3F:00:12"
}
