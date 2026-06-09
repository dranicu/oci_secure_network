###############################################################################
# OKE-mode topology.
#
# Active only when mode = "oke". Creates the canonical OCI OKE subnets plus
# Network Security Groups (NSGs) for the three traffic tiers:
#
#   - kube API endpoint subnet  (default: private /28)  + NSG
#   - worker nodes subnet       (private, NAT egress)   + NSG
#   - service load-balancer subnet (public by default; can be private) + NSG
#   - bastion subnet (optional, private) -- no NSG; the OCI Bastion service
#     handles its own networking
#
# Subnets inherit the VCN's empty default security list; all rule enforcement
# lives on the NSGs. Inter-tier rules reference NSGs by OCID rather than CIDR,
# so changing a subnet's CIDR later doesn't break them.
#
# Wire the NSG OCIDs into your OKE cluster resources:
#   - oci_containerengine_cluster.endpoint_config.nsg_ids = [oke.api_endpoint_nsg_id]
#   - oci_containerengine_node_pool.node_config_details.nsg_ids = [oke.workers_nsg_id]
#   - Kubernetes Service annotation:
#       oci.oraclecloud.com/oci-load-balancer-network-security-group: <oke.service_lb_nsg_id>
###############################################################################

###############################################################################
# NSGs
###############################################################################

resource "oci_core_network_security_group" "oke_api_endpoint" {
  count = local.is_oke ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-oke-api-nsg"
}

resource "oci_core_network_security_group" "oke_workers" {
  count = local.is_oke ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-oke-workers-nsg"
}

resource "oci_core_network_security_group" "oke_service_lb" {
  count = local.is_oke ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-oke-lb-nsg"
}

###############################################################################
# API endpoint NSG rules
###############################################################################

resource "oci_core_network_security_group_security_rule" "oke_api_in_workers_6443" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_api_endpoint[0].id
  description               = "Workers to kube-apiserver (6443)"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers[0].id
  source_type               = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_api_in_workers_12250" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_api_endpoint[0].id
  description               = "Workers to OKE control plane (12250)"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers[0].id
  source_type               = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_api_in_workers_icmp" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_api_endpoint[0].id
  description               = "Path MTU discovery from workers"
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = oci_core_network_security_group.oke_workers[0].id
  source_type               = "NETWORK_SECURITY_GROUP"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "oke_api_in_operators_6443" {
  for_each = local.is_oke ? toset(coalesce(var.oke.operator_cidrs, [])) : toset([])

  network_security_group_id = oci_core_network_security_group.oke_api_endpoint[0].id
  description               = "Operator workstation to kube API"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_api_eg_workers_tcp" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_api_endpoint[0].id
  description               = "Control plane to workers (TCP)"
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.oke_workers[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"
}

resource "oci_core_network_security_group_security_rule" "oke_api_eg_workers_icmp" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_api_endpoint[0].id
  description               = "Path MTU discovery to workers"
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = oci_core_network_security_group.oke_workers[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"

  icmp_options {
    type = 3
    code = 4
  }
}

###############################################################################
# Workers NSG rules
###############################################################################

resource "oci_core_network_security_group_security_rule" "oke_workers_in_self" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_workers[0].id
  description               = "Pod / worker intra-NSG"
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.oke_workers[0].id
  source_type               = "NETWORK_SECURITY_GROUP"
}

resource "oci_core_network_security_group_security_rule" "oke_workers_in_api_tcp" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_workers[0].id
  description               = "Control plane to workers (TCP)"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_api_endpoint[0].id
  source_type               = "NETWORK_SECURITY_GROUP"
}

resource "oci_core_network_security_group_security_rule" "oke_workers_in_api_icmp" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_workers[0].id
  description               = "Path MTU discovery from control plane"
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = oci_core_network_security_group.oke_api_endpoint[0].id
  source_type               = "NETWORK_SECURITY_GROUP"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "oke_workers_in_lb_nodeport" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_workers[0].id
  description               = "Service LB to workers on NodePort range"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_service_lb[0].id
  source_type               = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_workers_in_lb_health" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_workers[0].id
  description               = "Service LB health checks (kube-proxy)"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_service_lb[0].id
  source_type               = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_workers_in_bastion_ssh" {
  count = local.is_oke && var.oke.create_bastion_subnet ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_workers[0].id
  description               = "Bastion subnet SSH to workers"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.oke.bastion_subnet_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_workers_eg_any" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_workers[0].id
  description               = "Workers may reach anywhere (image pulls, patches, OCI services via Service Gateway)"
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

###############################################################################
# Service LB NSG rules
###############################################################################

resource "oci_core_network_security_group_security_rule" "oke_lb_in_https" {
  for_each = toset(local.oke_lb_sources)

  network_security_group_id = oci_core_network_security_group.oke_service_lb[0].id
  description               = "HTTPS to load balancer"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_lb_in_http" {
  for_each = toset(local.oke_lb_sources)

  network_security_group_id = oci_core_network_security_group.oke_service_lb[0].id
  description               = "HTTP to load balancer"
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_lb_eg_nodeport" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_service_lb[0].id
  description               = "LB to workers on NodePort range"
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.oke_workers[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_lb_eg_health" {
  count = local.is_oke ? 1 : 0

  network_security_group_id = oci_core_network_security_group.oke_service_lb[0].id
  description               = "LB health checks to workers (kube-proxy)"
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.oke_workers[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}

###############################################################################
# Subnets — no custom security_list_ids; rule enforcement is on the NSGs above.
###############################################################################

resource "oci_core_subnet" "oke_api_endpoint" {
  count = local.is_oke ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-oke-api"
  cidr_block     = var.oke.api_endpoint_cidr

  prohibit_public_ip_on_vnic = coalesce(var.oke.api_endpoint_visibility, "private") == "private"
  prohibit_internet_ingress  = coalesce(var.oke.api_endpoint_visibility, "private") == "private"

  route_table_id = coalesce(var.oke.api_endpoint_visibility, "private") == "public" ? oci_core_route_table.public[0].id : oci_core_route_table.private[0].id
}

resource "oci_core_subnet" "oke_workers" {
  count = local.is_oke ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-oke-workers"
  cidr_block     = var.oke.workers_cidr

  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true

  route_table_id = oci_core_route_table.private[0].id
}

resource "oci_core_subnet" "oke_service_lb" {
  count = local.is_oke ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-oke-lb"
  cidr_block     = var.oke.service_lb_cidr

  prohibit_public_ip_on_vnic = coalesce(var.oke.service_lb_visibility, "public") == "private"
  prohibit_internet_ingress  = coalesce(var.oke.service_lb_visibility, "public") == "private"

  route_table_id = coalesce(var.oke.service_lb_visibility, "public") == "public" ? oci_core_route_table.public[0].id : oci_core_route_table.private[0].id
}

resource "oci_core_subnet" "oke_bastion" {
  count = local.is_oke && var.oke.create_bastion_subnet ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-oke-bastion"
  cidr_block     = var.oke.bastion_subnet_cidr

  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true

  route_table_id = oci_core_route_table.private[0].id
}
