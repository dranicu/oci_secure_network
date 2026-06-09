variable "compartment_id" {
  description = "OCID of the compartment to deploy into."
  type        = string
}

variable "home_region" {
  description = "Tenancy home region (OCI Console -> Identity -> Region Management -> Home Region). The `security` module routes IAM writes here. Common values: us-ashburn-1, us-phoenix-1, eu-frankfurt-1."
  type        = string
}

variable "operator_cidr" {
  description = "Single-host /32 CIDR of the operator workstation allowed to reach the bastion. Find yours with: curl -s ifconfig.me"
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.operator_cidr))
    error_message = "operator_cidr must be a single-host IPv4 /32 CIDR (e.g. 198.51.100.10/32). Get yours with: curl -s ifconfig.me"
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file used to authorise managed-SSH bastion sessions."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "target_resource_id" {
  description = "OCID of an existing compute instance to create a managed-SSH bastion session against. Null skips session creation."
  type        = string
  default     = null
}
