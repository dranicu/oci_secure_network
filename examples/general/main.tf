###############################################################################
# General-purpose VCN + Bastion + Bastion session.
#
# Showcases the `security` module in general mode. Builds:
#   - a VCN with one bastion subnet and one application subnet (both private),
#     a NAT Gateway for egress and a Service Gateway for OCI services
#   - an NSG on the application tier that only accepts SSH from the bastion
#   - an OCI managed Bastion in the bastion subnet, locked to one operator /32
#   - (optional) a managed-SSH session against an existing instance you point
#     it at via var.target_resource_id
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

# Second OCI provider, pinned to the tenancy's home region. Required because
# the `security` module declares an IAM provider alias (IAM writes only work
# in the home region). Unused here since this example doesn't create IAM
# policies, but the alias must still be wired up.
provider "oci" {
  alias  = "home"
  region = var.home_region
}

module "security" {
  source = "../../modules/security"

  providers = {
    oci     = oci
    oci.iam = oci.home
  }

  compartment_id = var.compartment_id
  mode           = "general"
  vcn_name       = "test-general"

  subnets = {
    "bastion-subnet" = {
      cidr_block = "10.0.1.0/24"
      visibility = "private"
    }
    "app-subnet" = {
      cidr_block = "10.0.2.0/24"
      visibility = "private"
    }
  }

  network_security_groups = {
    app = {
      display_name = "test-general-app-nsg"
      ingress_rules = [{
        description = "SSH from the bastion subnet"
        protocol    = "6"
        source      = "10.0.1.0/24"
        port_min    = 22
        port_max    = 22
      }]
      egress_rules = [{
        description = "Outbound HTTPS for package updates (via NAT GW)"
        protocol    = "6"
        destination = "0.0.0.0/0"
        port_min    = 443
        port_max    = 443
      }]
    }
  }

  bastion = {
    name                         = "test-general-bastion"
    target_subnet                = "bastion-subnet"
    client_cidr_block_allow_list = [var.operator_cidr]
    max_session_ttl_in_seconds   = 10800
  }

  # Extra NSG rules — go through additional_nsg_rules so the module's
  # guardrails still apply. The `nsg` field is a key from
  # network_security_groups (above); for cross-NSG references, set source_nsg
  # or destination_nsg to another such key. Uncomment and adapt as needed.
  #
  # additional_nsg_rules = {
  #   "app-from-bastion-8080" = {
  #     nsg         = "app"
  #     direction   = "INGRESS"
  #     description = "Operator debug port from the bastion subnet"
  #     protocol    = "6"
  #     source_cidr = "10.0.1.0/24"
  #     port_min    = 8080
  #     port_max    = 8080
  #   }
  # }
}

###############################################################################
# Bastion session - created only when a target_resource_id is provided.
###############################################################################

resource "oci_bastion_session" "managed_ssh" {
  count = var.target_resource_id == null ? 0 : 1

  bastion_id   = module.security.bastion_id
  display_name = "general-managed-ssh"
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
