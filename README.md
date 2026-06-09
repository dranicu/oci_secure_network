# OCI Security Module

A single drop-in Terraform module that creates a secure Oracle Cloud
Infrastructure environment - VCN, subnets, gateways, route tables, Network
Security Groups, managed Bastion and IAM policies - and refuses to plan when
any of those inputs are insecure.

| What | Where |
|------|-------|
| The module | [`modules/security`](modules/security/) |
| End-to-end examples | [`examples/general`](examples/general/), [`examples/oke`](examples/oke/) |
| Security best-practices notes | [`secure-test-environment.md`](secure-test-environment.md) |

## Requirements

| Tool | Version |
|------|---------|
| Terraform | `>= 1.9.0` (cross-variable validation is required) |
| OCI provider | `>= 5.0.0` |

## What it does

A single `module "security"` block creates the whole environment:

- **VCN, subnets, gateways and route tables.** Two modes:
  - `mode = "general"` — VCN with the subnets you specify (`var.subnets`).
  - `mode = "oke"` — hardened OKE topology with the canonical API-endpoint /
    workers / load-balancer / bastion subnets and the OCI OKE security lists.
- **Network Security Groups** with input validation that refuses
  `0.0.0.0/0` on all ports, public admin/database ports, etc.
- **OCI managed Bastion** in a subnet from the VCN, allow-list locked to
  `/32` hosts only.
- **IAM policies** routed through a home-region provider alias (OCI requires
  IAM writes in the home region), with guardrails against tenancy-wide and
  unscoped admin grants.

Anything you don't ask for, the module doesn't create. `bastion` defaults to
`null`, `network_security_groups` and `iam_policies` default to `{}`.

## Quick start

The two providers — workload region (default) and home region (for IAM):

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    oci = { source = "oracle/oci", version = ">= 5.0.0" }
  }
}

provider "oci" {}                          # workload region (env / OCI CLI)
provider "oci" {
  alias  = "home"
  region = "us-ashburn-1"                  # your tenancy's home region
}

module "security" {
  source = "./modules/security"
  providers = {
    oci     = oci
    oci.iam = oci.home
  }

  compartment_id = var.compartment_id
  mode           = "general"
  vcn_name       = "test-env"

  subnets = {
    "private-app"  = { cidr_block = "10.0.2.0/24", visibility = "private" }
    "private-data" = { cidr_block = "10.0.3.0/24", visibility = "private" }
  }

  bastion = {
    name                         = "test-env-bastion"
    target_subnet                = "private-app"
    client_cidr_block_allow_list = ["203.0.113.10/32"]
  }
}
```

### A hardened OKE cluster's network

```hcl
module "security" {
  source = "./modules/security"
  providers = {
    oci     = oci
    oci.iam = oci.home
  }

  compartment_id = var.compartment_id
  mode           = "oke"
  vcn_name       = "oke-prod"

  oke = {
    api_endpoint_visibility = "private"          # no public kube API
    service_lb_visibility   = "private"          # no internet-facing LBs
    lb_ingress_cidrs        = ["10.50.0.0/16"]   # corporate network only
    operator_cidrs          = ["203.0.113.10/32"]
  }

  bastion = {
    name                         = "oke-prod-bastion"
    target_subnet                = "oke_bastion"
    client_cidr_block_allow_list = ["203.0.113.10/32"]
  }
}
```

Wire the OKE cluster and node pool to the module's outputs:

```hcl
data "oci_identity_availability_domain" "ad1" {
  compartment_id = var.compartment_id
  ad_number      = 1
}

resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_id
  kubernetes_version = "v1.30.1"
  name               = "oke-prod"

  vcn_id = module.security.vcn_id        # VCN OCID

  endpoint_config {
    subnet_id            = module.security.oke.api_endpoint_subnet_id   # kube API endpoint subnet
    nsg_ids              = [module.security.oke.api_endpoint_nsg_id]    # kube API endpoint NSG
    is_public_ip_enabled = false
  }

  options {
    service_lb_subnet_ids = [
      module.security.oke.service_lb_subnet_id,                         # Kubernetes Service LBs land here
    ]
  }
}

resource "oci_containerengine_node_pool" "workers" {
  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.compartment_id
  kubernetes_version = "v1.30.1"
  name               = "workers"
  node_shape         = "VM.Standard.E4.Flex"

  node_config_details {
    size    = 3
    nsg_ids = [module.security.oke.workers_nsg_id]                      # workers NSG
    placement_configs {
      availability_domain = data.oci_identity_availability_domain.ad1.name
      subnet_id           = module.security.oke.workers_subnet_id       # worker nodes live here
    }
  }
}
```

Kubernetes Services that publish a public load balancer need the LB NSG too,
via annotation:

```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    oci.oraclecloud.com/oci-load-balancer-network-security-group: "<oke.service_lb_nsg_id>"
spec:
  type: LoadBalancer
  ...
```

The OKE outputs you'll actually use:

| Output | Where to plug it in |
|--------|----------------------|
| `module.security.vcn_id` | `oci_containerengine_cluster.vcn_id` |
| `module.security.oke.api_endpoint_subnet_id` | `oci_containerengine_cluster.endpoint_config.subnet_id` |
| `module.security.oke.api_endpoint_nsg_id` | `oci_containerengine_cluster.endpoint_config.nsg_ids` |
| `module.security.oke.workers_subnet_id` | `oci_containerengine_node_pool.node_config_details.placement_configs.subnet_id` |
| `module.security.oke.workers_nsg_id` | `oci_containerengine_node_pool.node_config_details.nsg_ids` |
| `module.security.oke.service_lb_subnet_id` | `oci_containerengine_cluster.options.service_lb_subnet_ids` (or your Kubernetes Service `oci.oraclecloud.com/oci-load-balancer-subnet1` annotation) |
| `module.security.oke.service_lb_nsg_id` | Kubernetes Service annotation `oci.oraclecloud.com/oci-load-balancer-network-security-group` |
| `module.security.oke.bastion_subnet_id` | Already consumed by the module's own bastion. Surface only if you also deploy a non-OKE workload in that subnet. |

See [`modules/security/README.md`](modules/security/README.md) for every
input and output.

## Examples

| Example | What it builds |
|---------|----------------|
| [`examples/general`](examples/general/) | General-purpose VCN with bastion + app subnets, application NSG, managed Bastion locked to a single operator `/32`, optional managed-SSH session. |
| [`examples/oke`](examples/oke/) | Secure OKE VCN (private API endpoint by default), managed Bastion in the OKE bastion subnet, operator IAM policy, optional managed-SSH session against a worker node. |

Each example ships with a `terraform.tfvars.example` — copy to
`terraform.tfvars`, edit, then:

```bash
cd examples/general   # or examples/oke
terraform init
terraform apply
```

## What the module guarantees

- The VCN's **default security list** is overwritten to grant nothing — no
  forgotten subnet picks up permissive rules.
- Private subnets have `prohibit_public_ip_on_vnic = true` (a public IP
  cannot be attached, even by mistake).
- Internet Gateway is created **only when something actually needs it**.
- OKE mode's security lists are the OCI-recommended set: TCP 6443/12250 +
  ICMP path-MTU between control plane and workers, NodePort range + 10256
  between the LB and workers.
- The catastrophic NSG patterns are rejected at plan time: `0.0.0.0/0` with
  protocol "all", `0.0.0.0/0` TCP/UDP with no port range, and any `0.0.0.0/0`
  rule that covers an administrative or database port. Sensible public
  exposure (TCP 80/443 to the internet, etc.) is still allowed.
- Egress to `0.0.0.0/0` is allowed (image pulls, OS patching).
- The bastion's **client allow-list must be `/32` hosts only**.
- IAM statements granting **`manage all-resources in tenancy`** are
  rejected; every `manage` grant must be compartment-scoped.

## Adding more rules without forking the module

Pass extra rules through `additional_nsg_rules` on the module call. They
attach to NSGs the module already created, and **run through the same
guardrails as `network_security_groups`** — an unsafe rule fails plan, not
after the fact.

```hcl
module "security" {
  source = "./modules/security"
  # ...

  additional_nsg_rules = {
    # CIDR source on an OKE worker NSG (Prometheus scrape).
    "workers-from-monitoring" = {
      nsg         = "oke_workers"
      direction   = "INGRESS"
      description = "Prometheus scrape (node_exporter)"
      protocol    = "6"
      source_cidr = "10.0.50.0/24"
      port_min    = 9100
      port_max    = 9100
    }

    # Cross-NSG reference (LB NSG -> workers NSG).
    "workers-from-lb-9090" = {
      nsg         = "oke_workers"
      direction   = "INGRESS"
      description = "LB to workers on metrics aggregator port"
      protocol    = "6"
      source_nsg  = "oke_service_lb"
      port_min    = 9090
      port_max    = 9090
    }

    # Egress example: workers -> a corporate CIDR on HTTPS.
    "workers-egress-corp-https" = {
      nsg              = "oke_workers"
      direction        = "EGRESS"
      description      = "HTTPS to corporate network"
      protocol         = "6"
      destination_cidr = "10.60.0.0/16"
      port_min         = 443
      port_max         = 443
    }
  }
}
```

The `nsg` field is:

- a key from `network_security_groups` (general mode), or
- one of `oke_api_endpoint`, `oke_workers`, `oke_service_lb` (OKE mode).

`source_nsg` / `destination_nsg` use the same key set for cross-NSG
references.

### When you'd still reach for a raw resource

A brand-new NSG (one the module doesn't manage) still goes the raw-resource
route — point its `vcn_id` at `module.security.vcn_id`:

```hcl
resource "oci_core_network_security_group" "monitoring" {
  compartment_id = var.compartment_id
  vcn_id         = module.security.vcn_id
  display_name   = "monitoring-nsg"
}
```

You *can* also drop `oci_core_network_security_group_security_rule`
resources next to the module call using
`module.security.network_security_group_ids[...]` or
`module.security.oke.*_nsg_id`, but **those raw resources bypass the
guardrails** — Terraform variable validation can't reach them. Prefer
`additional_nsg_rules` whenever the NSG is one the module created.

## Layout

```
.
├── modules/
│   └── security/             ← VCN + subnets + gateways + NSGs + bastion + IAM
│       ├── vcn.tf            ← VCN + IGW/NAT/SGW + route tables + emptied default SL
│       ├── subnets.tf        ← general-mode subnets
│       ├── oke.tf            ← OKE subnets + canonical security lists
│       ├── nsg.tf            ← Network Security Groups + rules
│       ├── bastion.tf        ← managed Bastion service
│       ├── iam.tf            ← IAM policies (uses home-region provider alias)
│       ├── variables.tf      ← every guardrail lives here
│       ├── locals.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── README.md
├── examples/
│   ├── general/              ← general VCN + bastion + session
│   └── oke/                  ← secure OKE VCN + bastion + session
└── README.md                ← this file
```
