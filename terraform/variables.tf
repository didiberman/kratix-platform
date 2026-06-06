variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "server_name" {
  description = "Hetzner server name"
  type        = string
  default     = "kratix-idp"
}

variable "server_type" {
  description = "Hetzner server type (CPX22 = 3 vCPU, 4GB RAM)"
  type        = string
  default     = "cpx22"
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"
}
