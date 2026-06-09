resource "oci_core_network_security_group" "this" {
  for_each = var.network_security_groups

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = each.value.display_name
}

resource "oci_core_network_security_group_security_rule" "ingress" {
  for_each = local.ingress_rules

  network_security_group_id = oci_core_network_security_group.this[each.value.nsg_key].id
  direction                 = "INGRESS"
  protocol                  = each.value.protocol
  source                    = each.value.source
  source_type               = "CIDR_BLOCK"
  description               = each.value.description
  stateless                 = each.value.stateless

  dynamic "tcp_options" {
    for_each = each.value.protocol == "6" && each.value.port_min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.port_min
        max = each.value.port_max
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "17" && each.value.port_min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.port_min
        max = each.value.port_max
      }
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress" {
  for_each = local.egress_rules

  network_security_group_id = oci_core_network_security_group.this[each.value.nsg_key].id
  direction                 = "EGRESS"
  protocol                  = each.value.protocol
  destination               = each.value.destination
  destination_type          = "CIDR_BLOCK"
  description               = each.value.description
  stateless                 = each.value.stateless

  dynamic "tcp_options" {
    for_each = each.value.protocol == "6" && each.value.port_min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.port_min
        max = each.value.port_max
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "17" && each.value.port_min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.port_min
        max = each.value.port_max
      }
    }
  }
}

###############################################################################
# Additional NSG rules attached to NSGs the module already created.
#
# Variable validation (see variables.tf) enforces the same guardrails as
# network_security_groups before any of these get to plan, so an unsafe rule
# here fails the same way an unsafe rule in network_security_groups does.
###############################################################################

resource "oci_core_network_security_group_security_rule" "additional" {
  for_each = var.additional_nsg_rules

  network_security_group_id = local.all_module_nsg_lookup[each.value.nsg]
  direction                 = each.value.direction
  protocol                  = each.value.protocol
  description               = each.value.description
  stateless                 = each.value.stateless

  source = each.value.direction == "INGRESS" ? (
    each.value.source_nsg != null ? local.all_module_nsg_lookup[each.value.source_nsg] : each.value.source_cidr
  ) : null
  source_type = each.value.direction == "INGRESS" ? (
    each.value.source_nsg != null ? "NETWORK_SECURITY_GROUP" : "CIDR_BLOCK"
  ) : null

  destination = each.value.direction == "EGRESS" ? (
    each.value.destination_nsg != null ? local.all_module_nsg_lookup[each.value.destination_nsg] : each.value.destination_cidr
  ) : null
  destination_type = each.value.direction == "EGRESS" ? (
    each.value.destination_nsg != null ? "NETWORK_SECURITY_GROUP" : "CIDR_BLOCK"
  ) : null

  dynamic "tcp_options" {
    for_each = tostring(each.value.protocol) == "6" && each.value.port_min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.port_min
        max = each.value.port_max
      }
    }
  }

  dynamic "udp_options" {
    for_each = tostring(each.value.protocol) == "17" && each.value.port_min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.port_min
        max = each.value.port_max
      }
    }
  }
}
