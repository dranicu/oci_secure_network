variable "compartment_id" {
  description = "OCID of the compartment to deploy into."
  type        = string
}

variable "home_region" {
  description = "Tenancy home region (OCI Console -> Identity -> Region Management -> Home Region). The `security` module routes IAM writes here. Common values: us-ashburn-1, us-phoenix-1, eu-frankfurt-1."
  type        = string
}

variable "operator_cidr" {
  description = "Single-host /32 CIDR of the operator workstation allowed to reach the bastion."
  type        = string
  default     = "203.0.113.10/32"
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
