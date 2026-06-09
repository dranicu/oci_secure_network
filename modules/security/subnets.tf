###############################################################################
# General-mode subnets.
#
# Created only when mode = "general". Each entry in var.subnets becomes one
# regional subnet. Visibility 'public' routes via the Internet Gateway;
# 'private' routes via NAT + Service Gateway and structurally forbids public IPs.
###############################################################################

resource "oci_core_subnet" "general" {
  for_each = local.is_general ? var.subnets : {}

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = each.key
  cidr_block     = each.value.cidr_block
  dns_label      = each.value.dns_label

  prohibit_public_ip_on_vnic = each.value.visibility == "private"
  prohibit_internet_ingress  = each.value.visibility == "private"

  route_table_id = each.value.visibility == "public" ? oci_core_route_table.public[0].id : oci_core_route_table.private[0].id
}
