variable "vmware_workstation_api_url" {
  description = "VMware Workstation REST API endpoint. Defaults to localhost:8697."
  type        = string
  default     = "http://127.0.0.1:8697/api"
}

variable "vmware_workstation_user" {
  description = "VMware REST API username. Read from env VMWS_USER if unset."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vmware_workstation_password" {
  description = "VMware REST API password. Read from env VMWS_PASSWORD if unset."
  type        = string
  default     = ""
  sensitive   = true
}

variable "template_id" {
  description = "Sourceid of the Packer-built nexus-gateway template (vmworkstation provider ID)."
  type        = string
}

variable "vm_output_dir" {
  description = "Directory where the running VM instance is placed."
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
