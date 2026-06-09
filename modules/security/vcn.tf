###############################################################################
# VCN
###############################################################################

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  display_name   = var.vcn_name
  cidr_blocks    = var.vcn_cidr_blocks
  dns_label      = var.dns_label
}

###############################################################################
# Default security list — emptied so it grants nothing.
#
# OCI attaches a "default security list" to every VCN. If left untouched it
# applies to any subnet that does not explicitly attach its own security list.
# We replace its rules with an empty set so it is deny-by-default; real rules
# live on the subnet-specific security lists (OKE mode) or on NSGs.
###############################################################################

resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  display_name               = "${var.vcn_name}-default-sl-empty"
}

###############################################################################
# Gateways
###############################################################################

data "oci_core_services" "all" {
  count = local.create_sgw ? 1 : 0

  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_internet_gateway" "this" {
  count = local.create_igw ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "this" {
  count = local.create_nat ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-natgw"
}

resource "oci_core_service_gateway" "this" {
  count = local.create_sgw ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-sgw"

  services {
    service_id = data.oci_core_services.all[0].services[0].id
  }
}

###############################################################################
# Route tables
###############################################################################

resource "oci_core_route_table" "public" {
  count = local.create_igw ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-public-rt"

  route_rules {
    description       = "Default route to Internet Gateway"
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this[0].id
  }
}

resource "oci_core_route_table" "private" {
  count = local.create_nat || local.create_sgw ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-private-rt"

  dynamic "route_rules" {
    for_each = local.create_nat ? [1] : []
    content {
      description       = "Default egress via NAT Gateway"
      destination       = "0.0.0.0/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_nat_gateway.this[0].id
    }
  }

  dynamic "route_rules" {
    for_each = local.create_sgw ? [1] : []
    content {
      description       = "OCI services via Service Gateway"
      destination       = data.oci_core_services.all[0].services[0].cidr_block
      destination_type  = "SERVICE_CIDR_BLOCK"
      network_entity_id = oci_core_service_gateway.this[0].id
    }
  }
}
