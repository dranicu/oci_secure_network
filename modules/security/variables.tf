###############################################################################
# Placement
###############################################################################

variable "compartment_id" {
  description = "OCID of the compartment that owns the VCN, NSGs, bastion and IAM resources."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.compartment\\.", var.compartment_id))
    error_message = "compartment_id must be a compartment OCID (starts with 'ocid1.compartment.')."
  }
}

###############################################################################
# VCN mode
###############################################################################

variable "mode" {
  description = "VCN topology to create: 'general' for a VCN with arbitrary user-defined subnets, 'oke' for a hardened OKE-ready VCN with the canonical subnets and security lists."
  type        = string
  default     = "general"

  validation {
    condition     = contains(["general", "oke"], var.mode)
    error_message = "mode must be 'general' or 'oke'."
  }
}

###############################################################################
# VCN
###############################################################################

variable "vcn_name" {
  description = "Display name of the VCN. Used as a prefix for child resource names."
  type        = string
}

variable "vcn_cidr_blocks" {
  description = "IPv4 CIDR blocks for the VCN."
  type        = list(string)
  default     = ["10.0.0.0/16"]

  validation {
    condition     = length(var.vcn_cidr_blocks) > 0
    error_message = "vcn_cidr_blocks must contain at least one CIDR."
  }
}

variable "dns_label" {
  description = "DNS label for the VCN (lowercase alphanumeric, max 15 chars). Null disables internal DNS."
  type        = string
  default     = null
}

variable "create_service_gateway" {
  description = "Create a Service Gateway so workloads can reach OCI services (Object Storage, monitoring, registry) without traversing the internet."
  type        = bool
  default     = true
}

###############################################################################
# General-mode subnets
###############################################################################

variable "subnets" {
  description = "Subnets to create when mode = 'general'. Map key is the subnet display name. Visibility 'public' attaches an Internet Gateway route table; 'private' uses NAT + Service Gateway and structurally forbids public IPs."
  type = map(object({
    cidr_block = string
    visibility = string # "public" | "private"
    dns_label  = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for s in values(var.subnets) : contains(["public", "private"], s.visibility)])
    error_message = "Each subnet 'visibility' must be 'public' or 'private'."
  }
}

###############################################################################
# OKE-mode topology
###############################################################################

variable "oke" {
  description = "OKE topology configuration. Used only when mode = 'oke'. Defaults produce a private-API-endpoint cluster with public load balancers."
  type = object({
    api_endpoint_cidr       = optional(string, "10.0.0.0/28")
    api_endpoint_visibility = optional(string, "private") # "public" | "private"
    workers_cidr            = optional(string, "10.0.10.0/24")
    service_lb_cidr         = optional(string, "10.0.20.0/24")
    service_lb_visibility   = optional(string, "public") # "public" | "private"
    lb_ingress_cidrs        = optional(list(string), ["0.0.0.0/0"])
    operator_cidrs          = optional(list(string), [])
    create_bastion_subnet   = optional(bool, true)
    bastion_subnet_cidr     = optional(string, "10.0.1.0/24")
  })
  default = {}

  validation {
    condition     = contains(["public", "private"], coalesce(var.oke.api_endpoint_visibility, "private"))
    error_message = "oke.api_endpoint_visibility must be 'public' or 'private'."
  }
  validation {
    condition     = contains(["public", "private"], coalesce(var.oke.service_lb_visibility, "public"))
    error_message = "oke.service_lb_visibility must be 'public' or 'private'."
  }
  validation {
    condition     = alltrue([for c in coalesce(var.oke.operator_cidrs, []) : endswith(c, "/32")])
    error_message = "oke.operator_cidrs must contain only single-host /32 CIDRs."
  }
}

###############################################################################
# Network Security Groups
###############################################################################

variable "network_security_groups" {
  description = "Map of NSGs to create. Every ingress/egress rule is validated before any resource is planned. Public ingress (0.0.0.0/0 / ::/0) is allowed on legitimate ports (e.g. TCP 80/443 for a web server), but the catastrophic combinations are refused outright: all-protocols, no-port-range (all ports), or any administrative / database port."
  type = map(object({
    display_name = string
    ingress_rules = optional(list(object({
      description = string
      protocol    = string # "all", "1" (ICMP), "6" (TCP), "17" (UDP), "58" (ICMPv6)
      source      = string # CIDR
      port_min    = optional(number)
      port_max    = optional(number)
      stateless   = optional(bool, false)
    })), [])
    egress_rules = optional(list(object({
      description = string
      protocol    = string
      destination = string # CIDR
      port_min    = optional(number)
      port_max    = optional(number)
      stateless   = optional(bool, false)
    })), [])
  }))
  default = {}

  # --- Guardrail 1: never allow ALL protocols from the internet -------------
  validation {
    condition = alltrue([
      for nsg in values(var.network_security_groups) : alltrue([
        for r in nsg.ingress_rules :
        !(contains(["0.0.0.0/0", "::/0"], r.source) && lower(tostring(r.protocol)) == "all")
      ])
    ])
    error_message = "Insecure NSG rule: an ingress rule allows ALL protocols from 0.0.0.0/0 or ::/0. Restrict both the protocol and the source CIDR."
  }

  # --- Guardrail 2: never public TCP/UDP without an explicit port range -----
  validation {
    condition = alltrue([
      for nsg in values(var.network_security_groups) : alltrue([
        for r in nsg.ingress_rules :
        !(contains(["0.0.0.0/0", "::/0"], r.source) &&
          contains(["6", "17"], tostring(r.protocol)) &&
        (r.port_min == null || r.port_max == null))
      ])
    ])
    error_message = "Insecure NSG rule: a TCP/UDP ingress rule from 0.0.0.0/0 or ::/0 has no port range, which exposes every port. Set port_min and port_max."
  }

  # --- Guardrail 3: never public ingress that covers an admin/database port -
  validation {
    condition = alltrue([
      for nsg in values(var.network_security_groups) : alltrue([
        for r in nsg.ingress_rules :
        !contains(["0.0.0.0/0", "::/0"], r.source) ? true :
        r.port_min == null || r.port_max == null ? true :
        length([
          for p in [22, 23, 135, 139, 445, 1433, 1521, 2375, 2376, 3306, 3389, 5432, 5984, 6379, 8088, 9200, 11211, 27017] :
          p if p >= r.port_min && p <= r.port_max
        ]) == 0
      ])
    ])
    error_message = "Insecure NSG rule: an ingress rule from 0.0.0.0/0 or ::/0 covers an administrative or database port (22, 23, 135, 139, 445, 1433, 1521, 2375, 2376, 3306, 3389, 5432, 5984, 6379, 8088, 9200, 11211, 27017). Those must only be reachable through the bastion."
  }

  # --- Guardrail 4: protocol must be a known value -------------------------
  validation {
    condition = alltrue([
      for nsg in values(var.network_security_groups) : alltrue(concat(
        [for r in nsg.ingress_rules : contains(["all", "1", "6", "17", "58"], tostring(r.protocol))],
        [for r in nsg.egress_rules : contains(["all", "1", "6", "17", "58"], tostring(r.protocol))],
      ))
    ])
    error_message = "NSG rule protocol must be one of: \"all\", \"1\" (ICMP), \"6\" (TCP), \"17\" (UDP), \"58\" (ICMPv6)."
  }
}

###############################################################################
# Additional NSG rules — attach extra rules to NSGs the module already created
#
# Use this instead of writing raw oci_core_network_security_group_security_rule
# resources alongside the module call. Rules here run through the same
# guardrails as network_security_groups, so an unsafe rule fails plan.
#
# The `nsg` field selects the target NSG:
#   - any key from var.network_security_groups, or
#   - "oke_api_endpoint" / "oke_workers" / "oke_service_lb" when mode = "oke".
#
# For INGRESS rules, set exactly one of source_cidr or source_nsg.
# For EGRESS rules, set exactly one of destination_cidr or destination_nsg.
# *_nsg references resolve to one of the NSGs the module created (by the same
# key list as `nsg` above).
###############################################################################

variable "additional_nsg_rules" {
  description = "Extra ingress/egress rules to attach to NSGs the module already created. Uses the same guardrails as network_security_groups."
  type = map(object({
    nsg         = string
    direction   = string # "INGRESS" | "EGRESS"
    description = string
    protocol    = string # "all" | "1" (ICMP) | "6" (TCP) | "17" (UDP) | "58" (ICMPv6)

    source_cidr      = optional(string)
    source_nsg       = optional(string)
    destination_cidr = optional(string)
    destination_nsg  = optional(string)

    port_min  = optional(number)
    port_max  = optional(number)
    stateless = optional(bool, false)
  }))
  default = {}

  # --- Structural validity ---------------------------------------------------
  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) : contains(["INGRESS", "EGRESS"], r.direction)
    ])
    error_message = "additional_nsg_rules: direction must be 'INGRESS' or 'EGRESS'."
  }

  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      r.direction != "INGRESS" || ((r.source_cidr != null) != (r.source_nsg != null))
    ])
    error_message = "additional_nsg_rules: each INGRESS rule must set exactly one of source_cidr or source_nsg."
  }

  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      r.direction != "EGRESS" || ((r.destination_cidr != null) != (r.destination_nsg != null))
    ])
    error_message = "additional_nsg_rules: each EGRESS rule must set exactly one of destination_cidr or destination_nsg."
  }

  # --- Same NSG guardrails as network_security_groups -----------------------

  # Guardrail 1: no 0.0.0.0/0 + all protocols
  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      !(r.direction == "INGRESS" &&
        contains(["0.0.0.0/0", "::/0"], coalesce(r.source_cidr, "")) &&
      lower(tostring(r.protocol)) == "all")
    ])
    error_message = "Insecure NSG rule (additional_nsg_rules): an INGRESS rule allows ALL protocols from 0.0.0.0/0 or ::/0."
  }

  # Guardrail 2: no 0.0.0.0/0 TCP/UDP without an explicit port range
  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      !(r.direction == "INGRESS" &&
        contains(["0.0.0.0/0", "::/0"], coalesce(r.source_cidr, "")) &&
        contains(["6", "17"], tostring(r.protocol)) &&
      (r.port_min == null || r.port_max == null))
    ])
    error_message = "Insecure NSG rule (additional_nsg_rules): a TCP/UDP INGRESS from 0.0.0.0/0 or ::/0 has no port range. Set port_min and port_max."
  }

  # Guardrail 3: no 0.0.0.0/0 covering admin/db ports
  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      r.direction != "INGRESS" ? true :
      !contains(["0.0.0.0/0", "::/0"], coalesce(r.source_cidr, "")) ? true :
      r.port_min == null || r.port_max == null ? true :
      length([
        for p in [22, 23, 135, 139, 445, 1433, 1521, 2375, 2376, 3306, 3389, 5432, 5984, 6379, 8088, 9200, 11211, 27017] :
        p if p >= r.port_min && p <= r.port_max
      ]) == 0
    ])
    error_message = "Insecure NSG rule (additional_nsg_rules): an INGRESS from 0.0.0.0/0 or ::/0 covers an administrative or database port (22, 23, 135, 139, 445, 1433, 1521, 2375, 2376, 3306, 3389, 5432, 5984, 6379, 8088, 9200, 11211, 27017)."
  }

  # Guardrail 4: protocol must be a known value
  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      contains(["all", "1", "6", "17", "58"], tostring(r.protocol))
    ])
    error_message = "additional_nsg_rules: protocol must be one of \"all\", \"1\" (ICMP), \"6\" (TCP), \"17\" (UDP), \"58\" (ICMPv6)."
  }

  # NSG key references must resolve.
  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) : contains(concat(
        keys(var.network_security_groups),
        var.mode == "oke" ? ["oke_api_endpoint", "oke_workers", "oke_service_lb"] : []
      ), r.nsg)
    ])
    error_message = "additional_nsg_rules: 'nsg' must be a key from network_security_groups, or 'oke_api_endpoint' / 'oke_workers' / 'oke_service_lb' when mode = 'oke'."
  }

  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      r.source_nsg == null || contains(concat(
        keys(var.network_security_groups),
        var.mode == "oke" ? ["oke_api_endpoint", "oke_workers", "oke_service_lb"] : []
      ), r.source_nsg)
    ])
    error_message = "additional_nsg_rules: 'source_nsg' must reference a known NSG (a key from network_security_groups, or one of the oke_* keys in OKE mode)."
  }

  validation {
    condition = alltrue([
      for r in values(var.additional_nsg_rules) :
      r.destination_nsg == null || contains(concat(
        keys(var.network_security_groups),
        var.mode == "oke" ? ["oke_api_endpoint", "oke_workers", "oke_service_lb"] : []
      ), r.destination_nsg)
    ])
    error_message = "additional_nsg_rules: 'destination_nsg' must reference a known NSG (a key from network_security_groups, or one of the oke_* keys in OKE mode)."
  }
}

###############################################################################
# Bastion (OCI managed Bastion service)
###############################################################################

variable "bastion" {
  description = "OCI managed bastion configuration. Set to null to skip bastion creation. The target_subnet field is a key from var.subnets (general mode) or one of 'oke_api_endpoint', 'oke_workers', 'oke_lb', 'oke_bastion' (OKE mode)."
  type = object({
    name                         = string
    target_subnet                = string
    client_cidr_block_allow_list = list(string)
    max_session_ttl_in_seconds   = optional(number, 10800)
  })
  default = null

  validation {
    condition     = var.bastion == null || length(var.bastion.client_cidr_block_allow_list) > 0
    error_message = "bastion.client_cidr_block_allow_list must not be empty. An empty list lets OCI default to allowing every client IP."
  }

  validation {
    condition     = var.bastion == null || length(var.bastion.client_cidr_block_allow_list) <= 20
    error_message = "bastion.client_cidr_block_allow_list may contain at most 20 entries (OCI service limit)."
  }

  validation {
    condition     = var.bastion == null || alltrue([for c in var.bastion.client_cidr_block_allow_list : endswith(c, "/32")])
    error_message = "bastion.client_cidr_block_allow_list may only contain single-host /32 CIDRs (e.g. <your_ip_address>/32). Wider ranges, and 0.0.0.0/0, are rejected."
  }

  validation {
    condition     = var.bastion == null || (var.bastion.max_session_ttl_in_seconds >= 1800 && var.bastion.max_session_ttl_in_seconds <= 10800)
    error_message = "bastion.max_session_ttl_in_seconds must be between 1800 (30m) and 10800 (3h)."
  }
}

###############################################################################
# IAM policies
###############################################################################

variable "allow_compartment_admin" {
  description = "Escape hatch: when true, a statement may use 'manage all-resources' scoped to a compartment. Tenancy-wide admin is always rejected."
  type        = bool
  default     = false
}

variable "iam_policies" {
  description = "Map of IAM policies to create. Statements are validated to forbid tenancy-wide and unscoped admin grants. Pass an empty map to skip IAM creation."
  type = map(object({
    name        = string
    description = string
    statements  = list(string)
  }))
  default = {}

  # --- Guardrail 4: no tenancy-wide administrator -------------------------
  validation {
    condition = alltrue([
      for p in values(var.iam_policies) : alltrue([
        for s in p.statements :
        !can(regex("(?i)manage\\s+all-resources\\s+in\\s+tenancy", s))
      ])
    ])
    error_message = "Insecure IAM policy: a statement grants 'manage all-resources in tenancy' (full tenancy administrator). Remove it."
  }

  # --- Guardrail 5: every 'manage' grant must be compartment-scoped -------
  validation {
    condition = alltrue([
      for p in values(var.iam_policies) : alltrue([
        for s in p.statements :
        !can(regex("(?i)\\bmanage\\b[^\\n]*\\bin\\s+tenancy\\b", s))
      ])
    ])
    error_message = "Insecure IAM policy: a 'manage' statement is scoped 'in tenancy'. Scope every manage grant to a specific compartment."
  }

  # --- Guardrail 6: no compartment-wide admin unless explicitly opted in --
  validation {
    condition = var.allow_compartment_admin || alltrue([
      for p in values(var.iam_policies) : alltrue([
        for s in p.statements :
        !can(regex("(?i)manage\\s+all-resources", s))
      ])
    ])
    error_message = "Insecure IAM policy: 'manage all-resources' grants compartment-wide admin. List explicit resource-type families instead, or set allow_compartment_admin = true to override."
  }
}
