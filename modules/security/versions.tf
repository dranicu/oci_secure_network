terraform {
  # 1.9.0 is required: cross-variable references inside `validation` blocks
  # (the network rules validate against `var.permitted_public_ingress_ports`).
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
      # IAM resources must be created in the tenancy's home region. The caller
      # passes a provider alias pointed at the home region; everything else
      # (VCN, subnets, NSGs, bastion) uses the default provider for the
      # workload region.
      configuration_aliases = [oci.iam]
    }
  }
}
