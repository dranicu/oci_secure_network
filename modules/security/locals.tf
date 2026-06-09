locals {
  ###############################################################################
  # Mode flags
  ###############################################################################
  is_general = var.mode == "general"
  is_oke     = var.mode == "oke"

  ###############################################################################
  # Gateway decisions
  ###############################################################################
  has_public_subnet  = local.is_general && anytrue([for s in values(var.subnets) : s.visibility == "public"])
  has_private_subnet = local.is_general && anytrue([for s in values(var.subnets) : s.visibility == "private"])

  oke_needs_igw = local.is_oke && (
    coalesce(var.oke.service_lb_visibility, "public") == "public" ||
    coalesce(var.oke.api_endpoint_visibility, "private") == "public"
  )

  create_igw = local.has_public_subnet || local.oke_needs_igw
  create_nat = local.has_private_subnet || local.is_oke
  create_sgw = var.create_service_gateway

  ###############################################################################
  # OKE LB ingress sources
  ###############################################################################
  oke_lb_sources = local.is_oke ? (
    coalesce(var.oke.service_lb_visibility, "public") == "public"
    ? ["0.0.0.0/0"]
    : coalesce(var.oke.lb_ingress_cidrs, [])
  ) : []

  ###############################################################################
  # NSG rule flattening
  ###############################################################################
  ingress_rules = merge([
    for nsg_key, nsg in var.network_security_groups : {
      for idx, rule in nsg.ingress_rules :
      "${nsg_key}-ingress-${idx}" => merge(rule, { nsg_key = nsg_key })
    }
  ]...)

  egress_rules = merge([
    for nsg_key, nsg in var.network_security_groups : {
      for idx, rule in nsg.egress_rules :
      "${nsg_key}-egress-${idx}" => merge(rule, { nsg_key = nsg_key })
    }
  ]...)

  ###############################################################################
  # Bastion target-subnet resolution
  #
  # Builds a map of "logical key" -> subnet OCID across the subnets this module
  # creates, then looks up var.bastion.target_subnet against it.
  ###############################################################################
  bastion_enabled = var.bastion != null

  subnet_id_lookup = merge(
    { for k, s in oci_core_subnet.general : k => s.id },
    local.is_oke ? {
      oke_api_endpoint = oci_core_subnet.oke_api_endpoint[0].id
      oke_workers      = oci_core_subnet.oke_workers[0].id
      oke_lb           = oci_core_subnet.oke_service_lb[0].id
      oke_bastion      = try(oci_core_subnet.oke_bastion[0].id, null)
    } : {}
  )

  bastion_target_subnet_id = local.bastion_enabled ? local.subnet_id_lookup[var.bastion.target_subnet] : null

  ###############################################################################
  # NSG lookup map for additional_nsg_rules
  ###############################################################################
  all_module_nsg_lookup = merge(
    { for k, v in oci_core_network_security_group.this : k => v.id },
    local.is_oke ? {
      oke_api_endpoint = oci_core_network_security_group.oke_api_endpoint[0].id
      oke_workers      = oci_core_network_security_group.oke_workers[0].id
      oke_service_lb   = oci_core_network_security_group.oke_service_lb[0].id
    } : {}
  )
}
