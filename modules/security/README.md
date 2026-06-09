# `security` Terraform module (OCI)

A single drop-in module that creates the secure OCI environment from end to
end:

- **VCN** with subnets, gateways and route tables. Two modes:
  - `mode = "general"` — VCN with the subnets you specify (public or
    private). Add or remove entries in `var.subnets`.
  - `mode = "oke"` — hardened OKE-ready VCN with the canonical OCI OKE
    topology and security lists already in place.
- **Network Security Groups** with `validation` blocks that **refuse to plan**
  insecure rules.
- **OCI managed Bastion** sitting in a subnet from the VCN, with the client
  allow-list pinned to `/32` hosts only.
- **IAM policies** routed through a home-region provider alias, with
  guardrails against tenancy-wide and unscoped admin grants.

Anything you don't ask for, it doesn't create — `bastion` defaults to `null`,
`network_security_groups` and `iam_policies` default to `{}`.

## What it always creates

| Resource | Purpose |
|----------|---------|
| `oci_core_vcn` | The VCN |
| Empty default security list | Replaces OCI's permissive default — nothing rides on it by accident |
| Service Gateway (default on) | OCI services without crossing the internet |
| NAT Gateway | Created when any private subnet exists (or OKE mode) |
| Internet Gateway | Created when any public subnet exists (or OKE has a public LB / API endpoint) |
| Public + private route tables | Wired to the right gateways |

Gateways and route tables you don't need are silently skipped.

## Provider aliases

IAM resources can only be written in the tenancy's home region (OCI quirk).
The module declares a `configuration_aliases = [oci.iam]` so the caller maps
two providers:

```hcl
module "security" {
  source = "./modules/security"
  providers = {
    oci     = oci          # workload region - VCN, subnets, NSGs, bastion
    oci.iam = oci.home     # tenancy home region - IAM policies
  }
  ...
}
```

The caller declares the home-region provider:

```hcl
provider "oci" {
  alias  = "home"
  region = "us-ashburn-1"   # your tenancy's home region
}
```

## Guardrails — what the module refuses to plan

| # | Guardrail | Variable |
|---|-----------|----------|
| 1 | No `0.0.0.0/0` ingress with protocol **"all"** | `network_security_groups` |
| 2 | No `0.0.0.0/0` TCP/UDP ingress **without an explicit port range** (= every port) | `network_security_groups` |
| 3 | No `0.0.0.0/0` ingress that covers an **administrative or database port** (22, 23, 135, 139, 445, 1433, 1521, 2375, 2376, 3306, 3389, 5432, 5984, 6379, 8088, 9200, 11211, 27017) | `network_security_groups` |
| 4 | NSG rule protocols must be one of the known values (`all`, `1`, `6`, `17`, `58`) | `network_security_groups` |
| 5 | The bastion client allow-list contains **only `/32` hosts** — no `0.0.0.0/0`, no wide ranges, never empty | `bastion` |
| 6 | No IAM statement grants **`manage all-resources in tenancy`** | `iam_policies` |
| 7 | Every `manage` grant is **compartment-scoped**; compartment-wide `manage all-resources` needs `allow_compartment_admin = true` | `iam_policies` + `allow_compartment_admin` |

Sensible public exposure (TCP 80/443 to the internet for a web server, ICMP
from anywhere, etc.) is still allowed — only the catastrophic patterns are
refused.

## Inputs

### Placement and mode

| Name | Type | Default | Required |
|------|------|---------|:--------:|
| `compartment_id` | `string` | — | yes |
| `mode` | `"general" \| "oke"` | `"general"` | no |
| `vcn_name` | `string` | — | yes |
| `vcn_cidr_blocks` | `list(string)` | `["10.0.0.0/16"]` | no |
| `dns_label` | `string` | `null` | no |
| `create_service_gateway` | `bool` | `true` | no |

### `mode = "general"`

```hcl
subnets = map(object({
  cidr_block = string
  visibility = "public" | "private"
  dns_label  = optional(string)
}))
```

### `mode = "oke"`

```hcl
oke = object({
  api_endpoint_cidr       = optional(string, "10.0.0.0/28")
  api_endpoint_visibility = optional(string, "private")
  workers_cidr            = optional(string, "10.0.10.0/24")
  service_lb_cidr         = optional(string, "10.0.20.0/24")
  service_lb_visibility   = optional(string, "public")
  lb_ingress_cidrs        = optional(list(string), ["0.0.0.0/0"])
  operator_cidrs          = optional(list(string), [])
  create_bastion_subnet   = optional(bool, true)
  bastion_subnet_cidr     = optional(string, "10.0.1.0/24")
})
```

### NSGs

```hcl
network_security_groups = map(object({
  display_name = string
  ingress_rules = optional(list(object({
    description = string
    protocol    = string   # "all" | "1" (ICMP) | "6" (TCP) | "17" (UDP) | "58" (ICMPv6)
    source      = string   # CIDR — must NOT be 0.0.0.0/0 or ::/0
    port_min    = optional(number)
    port_max    = optional(number)
    stateless   = optional(bool, false)
  })), [])
  egress_rules = optional(list(object({
    description = string
    protocol    = string
    destination = string
    port_min    = optional(number)
    port_max    = optional(number)
    stateless   = optional(bool, false)
  })), [])
}))
```

Egress to `0.0.0.0/0` is allowed (workloads legitimately need to reach
package mirrors, container registries and OCI services). Public ingress is
allowed on sensible ports (e.g. TCP 80/443 for a web server) — only the
catastrophic patterns are refused: protocol "all", TCP/UDP with no port
range, and any rule covering an admin or database port.

### Additional NSG rules

Extra rules for NSGs the module already created. Same guardrails as
`network_security_groups` — an unsafe entry here fails plan.

```hcl
additional_nsg_rules = map(object({
  nsg         = string   # which NSG to attach to (see below)
  direction   = string   # "INGRESS" | "EGRESS"
  description = string
  protocol    = string   # "all" | "1" | "6" | "17" | "58"

  # INGRESS: set exactly one of source_cidr / source_nsg.
  source_cidr = optional(string)
  source_nsg  = optional(string)

  # EGRESS: set exactly one of destination_cidr / destination_nsg.
  destination_cidr = optional(string)
  destination_nsg  = optional(string)

  port_min  = optional(number)
  port_max  = optional(number)
  stateless = optional(bool, false)
}))
```

The `nsg` / `source_nsg` / `destination_nsg` fields refer to module-managed
NSGs by key:

- any key from `network_security_groups`, or
- `oke_api_endpoint`, `oke_workers`, `oke_service_lb` when `mode = "oke"`.

This is the safe alternative to writing raw
`oci_core_network_security_group_security_rule` resources next to the
module — those bypass `validation` blocks. Use this variable to keep the
guardrails on.

### Bastion

```hcl
bastion = object({
  name                         = string
  target_subnet                = string   # key into the subnets the module creates
  client_cidr_block_allow_list = list(string)
  max_session_ttl_in_seconds   = optional(number, 10800)
})
```

`target_subnet` is a **key**, not an OCID:

- In `mode = "general"`: any key from `var.subnets`.
- In `mode = "oke"`: one of `oke_api_endpoint`, `oke_workers`, `oke_lb`,
  `oke_bastion`.

Set `bastion = null` to skip bastion creation.

### IAM

```hcl
iam_policies = map(object({
  name        = string
  description = string
  statements  = list(string)
}))

allow_compartment_admin = bool   # default false
```

Set `iam_policies = {}` (the default) to skip IAM creation.

## Outputs

| Output | Description |
|--------|-------------|
| `vcn_id`, `vcn_cidr_blocks` | The VCN |
| `internet_gateway_id`, `nat_gateway_id`, `service_gateway_id` | Gateway OCIDs (`null` if absent) |
| `public_route_table_id`, `private_route_table_id` | Route table OCIDs (`null` if absent) |
| `subnet_ids` | Map of general-mode subnet name → OCID |
| `oke` | Object with `api_endpoint_subnet_id`, `workers_subnet_id`, `service_lb_subnet_id`, `bastion_subnet_id` and matching NSG OCIDs (`api_endpoint_nsg_id`, `workers_nsg_id`, `service_lb_nsg_id`). `null` when `mode != "oke"`. The NSG OCIDs must be wired into the cluster's `endpoint_config.nsg_ids`, the node pool's `node_config_details.nsg_ids`, and any public Service's `oci.oraclecloud.com/oci-load-balancer-network-security-group` annotation. |
| `network_security_group_ids` | Map of NSG key → OCID |
| `bastion_id` | Bastion OCID (`null` when no bastion was created) |
| `iam_policy_ids` | Map of policy key → OCID |

## Examples

Working configurations live in [`../../examples`](../../examples):

- [`examples/general`](../../examples/general/) — VCN with bastion + app
  subnets, NSG, managed Bastion, optional managed-SSH session.
- [`examples/oke`](../../examples/oke/) — secure OKE VCN, managed Bastion in
  the OKE bastion subnet, IAM policy for the operators group, optional
  managed-SSH session.
