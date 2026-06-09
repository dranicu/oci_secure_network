###############################################################################
# VCN / network
###############################################################################

output "vcn_id" {
  description = "OCID of the created VCN."
  value       = oci_core_vcn.this.id
}

output "vcn_cidr_blocks" {
  description = "IPv4 CIDR blocks of the VCN."
  value       = oci_core_vcn.this.cidr_blocks
}

output "internet_gateway_id" {
  description = "OCID of the Internet Gateway, or null if none was created."
  value       = try(oci_core_internet_gateway.this[0].id, null)
}

output "nat_gateway_id" {
  description = "OCID of the NAT Gateway, or null if none was created."
  value       = try(oci_core_nat_gateway.this[0].id, null)
}

output "service_gateway_id" {
  description = "OCID of the Service Gateway, or null if none was created."
  value       = try(oci_core_service_gateway.this[0].id, null)
}

output "public_route_table_id" {
  description = "OCID of the public route table, or null if none was created."
  value       = try(oci_core_route_table.public[0].id, null)
}

output "private_route_table_id" {
  description = "OCID of the private route table, or null if none was created."
  value       = try(oci_core_route_table.private[0].id, null)
}

###############################################################################
# Subnets
###############################################################################

output "subnet_ids" {
  description = "Map of general-mode subnet display name to OCID."
  value       = { for k, v in oci_core_subnet.general : k => v.id }
}

output "oke" {
  description = "OKE topology resource OCIDs. Null when mode != 'oke'. The NSG OCIDs must be wired into your cluster / node-pool / Service definitions."
  value = local.is_oke ? {
    api_endpoint_subnet_id = oci_core_subnet.oke_api_endpoint[0].id
    workers_subnet_id      = oci_core_subnet.oke_workers[0].id
    service_lb_subnet_id   = oci_core_subnet.oke_service_lb[0].id
    bastion_subnet_id      = try(oci_core_subnet.oke_bastion[0].id, null)
    api_endpoint_nsg_id    = oci_core_network_security_group.oke_api_endpoint[0].id
    workers_nsg_id         = oci_core_network_security_group.oke_workers[0].id
    service_lb_nsg_id      = oci_core_network_security_group.oke_service_lb[0].id
  } : null
}

###############################################################################
# Security
###############################################################################

output "network_security_group_ids" {
  description = "Map of NSG key to created NSG OCID."
  value       = { for k, v in oci_core_network_security_group.this : k => v.id }
}

output "bastion_id" {
  description = "Bastion OCID, or null when no bastion was created."
  value       = try(oci_bastion_bastion.this[0].id, null)
}

output "iam_policy_ids" {
  description = "Map of IAM policy key to created policy OCID."
  value       = { for k, v in oci_identity_policy.this : k => v.id }
}
