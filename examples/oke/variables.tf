variable "compartment_id" {
  description = "OCID of the compartment to deploy into."
  type        = string
}

variable "home_region" {
  description = "Tenancy home region (OCI Console -> Identity -> Region Management -> Home Region). IAM resources must be created here. Common values: us-ashburn-1, us-phoenix-1, eu-frankfurt-1."
  type        = string
}

variable "operator_cidr" {
  description = "Single-host /32 CIDR of the operator workstation allowed to reach the bastion and the kube API."
  type        = string
  default     = "203.0.113.10/32"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file used to authorise managed-SSH bastion sessions."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "target_resource_id" {
  description = "OCID of an existing OKE worker (or any compute instance reachable from the bastion subnet) to create a managed-SSH session against. Null skips session creation."
  type        = string
  default     = null
}

variable "create_iam_policies" {
  description = "Whether to create the OKE operator IAM policies. Set to false if the operator group already has equivalent policies attached (bastion-session manage + read on cluster / instance / virtual-network families in the target compartment)."
  type        = bool
  default     = true
}

variable "operator_group_name" {
  description = "Name of the existing OCI IAM group whose members receive the OKE operator policies. The group must already exist; only the policies are created."
  type        = string
  default     = "test-oke-operators"
}
