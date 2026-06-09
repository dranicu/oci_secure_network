output "vcn_id" {
  value = module.security.vcn_id
}

output "oke_subnets" {
  description = "OCIDs of the OKE subnets - wire these into your oci_containerengine_cluster / node_pool resources."
  value       = module.security.oke
}

output "bastion_id" {
  value = module.security.bastion_id
}

output "bastion_session_id" {
  description = "OCID of the managed-SSH session, or null if no target_resource_id was provided."
  value       = try(oci_bastion_session.managed_ssh[0].id, null)
}

output "ssh_command" {
  description = "SSH invocation returned by the bastion session, or null if no session was created."
  value       = try(oci_bastion_session.managed_ssh[0].ssh_metadata["command"], null)
}
