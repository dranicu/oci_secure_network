###############################################################################
# Secure OKE VCN + Bastion + Bastion session.
#
# Showcases the `security` module in OKE mode. Builds:
#   - the canonical OKE VCN topology (API endpoint, workers, service LB,
#     bastion subnets) with the OCI-recommended security lists
#   - a private kube API endpoint and (by default) public service LBs
#   - an OCI managed Bastion in the dedicated bastion subnet, locked to one
#     operator /32
#   - IAM policy for the OKE operators group (validated by the module's
#     guardrails - no tenancy-wide admin etc.)
#   - (optional) a managed-SSH session against a worker node you point it at
#     via var.target_resource_id
#
# This does not create the OKE cluster itself. Wire the subnet OCIDs from
# `module.security.oke` into oci_containerengine_cluster /
# oci_containerengine_node_pool in your configuration.
#
# Apply:
#   cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
#   terraform init
#   terraform apply
###############################################################################

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
  }
}

provider "oci" {
  # Workload region - picked up from your OCI CLI config / env.
}

# Second OCI provider, pinned to the tenancy's home region. The OCI Identity
# service rejects write operations on policies / groups / users outside the
# home region; the `security` module's IAM resource uses this aliased provider.
provider "oci" {
  alias  = "home"
  region = var.home_region
}

# Look up the compartment name so policy statements can reference it without
# hardcoding (`Allow ... in compartment <name>` rejects unknown names).
data "oci_identity_compartment" "this" {
  id = var.compartment_id
}

module "security" {
  source = "../../modules/security"

  providers = {
    oci     = oci
    oci.iam = oci.home
  }

  compartment_id = var.compartment_id
  mode           = "oke"
  vcn_name       = "test-oke"

  oke = {
    # Private kube API endpoint - operators reach it via the bastion or a
    # peered network, not from the public internet.
    api_endpoint_visibility = "private"
    api_endpoint_cidr       = "10.0.0.0/28"

    workers_cidr = "10.0.10.0/24"

    # Public service load balancers (typical web-facing cluster). Set to
    # "private" to make this an internal-only cluster.
    service_lb_visibility = "public"
    service_lb_cidr       = "10.0.20.0/24"

    # Operator workstations allowed to reach the kube API directly (e.g. for
    # kubectl through the bastion's port-forwarding session). Each must be /32.
    operator_cidrs = [var.operator_cidr]

    create_bastion_subnet = true
    bastion_subnet_cidr   = "10.0.1.0/24"
  }

  bastion = {
    name                         = "test-oke-bastion"
    target_subnet                = "oke_bastion"
    client_cidr_block_allow_list = [var.operator_cidr]
    max_session_ttl_in_seconds   = 10800
  }

  # Skip when equivalent policies already exist on the operator group
  # (set var.create_iam_policies = false).
  iam_policies = var.create_iam_policies ? {
    operators = {
      name        = "${var.operator_group_name}-policy"
      description = "Least-privilege OKE operator access (bastion + read-only on cluster + instance + network)"
      statements = [
        "Allow group ${var.operator_group_name} to manage bastion-session in compartment ${data.oci_identity_compartment.this.name}",
        "Allow group ${var.operator_group_name} to read cluster-family in compartment ${data.oci_identity_compartment.this.name}",
        "Allow group ${var.operator_group_name} to read instance-family in compartment ${data.oci_identity_compartment.this.name}",
        "Allow group ${var.operator_group_name} to read virtual-network-family in compartment ${data.oci_identity_compartment.this.name}",
      ]
    }
  } : {}

  # Extra NSG rules — go through additional_nsg_rules so the module's
  # guardrails still apply. The `nsg` field selects which NSG to attach to:
  # "oke_api_endpoint", "oke_workers" or "oke_service_lb". For cross-NSG
  # references use source_nsg / destination_nsg with the same keys.
  # Uncomment and adapt as needed.
  #
  # additional_nsg_rules = {
  #   "workers-from-monitoring" = {
  #     nsg         = "oke_workers"
  #     direction   = "INGRESS"
  #     description = "Prometheus scrape (node_exporter)"
  #     protocol    = "6"
  #     source_cidr = "10.0.50.0/24"
  #     port_min    = 9100
  #     port_max    = 9100
  #   }
  #   "workers-from-lb-9090" = {
  #     nsg         = "oke_workers"
  #     direction   = "INGRESS"
  #     description = "LB to workers on the metrics aggregator port"
  #     protocol    = "6"
  #     source_nsg  = "oke_service_lb"
  #     port_min    = 9090
  #     port_max    = 9090
  #   }
  # }
}

###############################################################################
# Bastion session - created only when a target_resource_id is provided.
# For OKE this is typically the OCID of a worker node you want a shell on.
###############################################################################

resource "oci_bastion_session" "managed_ssh" {
  count = var.target_resource_id == null ? 0 : 1

  bastion_id   = module.security.bastion_id
  display_name = "oke-worker-managed-ssh"
  key_type     = "PUB"

  key_details {
    public_key_content = file(pathexpand(var.ssh_public_key_path))
  }

  target_resource_details {
    session_type                               = "MANAGED_SSH"
    target_resource_id                         = var.target_resource_id
    target_resource_operating_system_user_name = "opc"
    target_resource_port                       = 22
  }

  session_ttl_in_seconds = 3600
}
