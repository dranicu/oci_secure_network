# OCI managed Bastion service.
#
# The target subnet is resolved from `var.bastion.target_subnet` against the
# subnets this module creates (see locals.subnet_id_lookup). For OKE mode the
# valid keys are: oke_api_endpoint, oke_workers, oke_lb, oke_bastion. For
# general mode they are the keys of var.subnets.
resource "oci_bastion_bastion" "this" {
  count = local.bastion_enabled ? 1 : 0

  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_id
  target_subnet_id             = local.bastion_target_subnet_id
  name                         = var.bastion.name
  client_cidr_block_allow_list = var.bastion.client_cidr_block_allow_list
  max_session_ttl_in_seconds   = var.bastion.max_session_ttl_in_seconds
}
