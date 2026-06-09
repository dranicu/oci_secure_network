# IAM policies. Statements are validated in variables.tf to reject tenancy-wide
# administrator grants and unscoped 'manage' verbs before this is planned.
#
# IAM writes are only accepted in the tenancy's home region, so this resource
# uses the aliased provider the caller wires up (see versions.tf).
resource "oci_identity_policy" "this" {
  provider = oci.iam

  for_each = var.iam_policies

  compartment_id = var.compartment_id
  name           = each.value.name
  description    = each.value.description
  statements     = each.value.statements
}
