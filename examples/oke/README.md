# Example — secure OKE VCN with bastion

Showcases the [`security`](../../modules/security/) module in `mode = "oke"`:

- The canonical OCI **OKE VCN topology**: kube-API-endpoint subnet, worker
  nodes subnet, service-load-balancer subnet and a dedicated bastion subnet,
  with the OKE-recommended security lists already attached.
- A **private kube API endpoint** - operators reach it via the bastion or a
  peered network, never from the public internet.
- An **OCI managed Bastion** in the bastion subnet, pinned to one operator
  `/32`.
- IAM policy for the OKE operators group (bastion session + read-only on
  cluster / instance / network families). The module's guardrails reject any
  tenancy-wide grant at plan time.
- Optionally, a managed-SSH session against an existing worker node.

This example creates the **network** the cluster lives in. It does not
create the OKE cluster itself - feed `module.security.oke.api_endpoint_subnet_id`,
`workers_subnet_id` and `service_lb_subnet_id` into your
`oci_containerengine_cluster` and `oci_containerengine_node_pool` resources.

## Apply

The fastest path is to copy the tfvars example and edit it:

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init
terraform apply
```

Or pass variables on the command line:

```bash
terraform init
terraform apply \
  -var compartment_id=ocid1.compartment.oc1..xxxxx \
  -var home_region=us-ashburn-1 \
  -var operator_cidr=$(curl -s ifconfig.me)/32
```

To also create a managed-SSH session against an existing worker node:

```bash
terraform apply -var target_resource_id=ocid1.instance.oc1..yyyyy
```

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `compartment_id` | — | Compartment OCID to deploy into. |
| `home_region` | — | Tenancy home region (Identity → Region Management). IAM writes go here. |
| `operator_cidr` | — | Single-host `/32` for both the bastion allow-list and `oke.operator_cidrs`. Required. Get yours with `curl -s ifconfig.me`. |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | Public key the bastion session will authorise. |
| `target_resource_id` | `null` | OCID of an existing worker to create a session against; null skips the session. |
| `create_iam_policies` | `true` | Set to `false` if the operator group already has equivalent policies. |
| `operator_group_name` | `test-oke-operators` | Name of the existing IAM group that the policies grant access to. The group must already exist. |

## Outputs

| Output | Description |
|--------|-------------|
| `vcn_id` | VCN OCID. |
| `oke_subnets` | Object with `api_endpoint_subnet_id`, `workers_subnet_id`, `service_lb_subnet_id`, `bastion_subnet_id`, plus the matching security-list OCIDs. |
| `bastion_id` | Bastion OCID. |
| `bastion_session_id` | Session OCID, or null. |
| `ssh_command` | The `ssh -o ProxyCommand=...` line the bastion returns. |

## Making it more restrictive

The defaults produce a cluster with a private kube API endpoint and **public**
service load balancers (typical web-facing cluster). For a fully internal
cluster, edit `main.tf`:

```hcl
oke = {
  api_endpoint_visibility = "private"
  service_lb_visibility   = "private"
  lb_ingress_cidrs        = ["10.50.0.0/16"]   # the corporate network
  ...
}
```

That removes the Internet Gateway entirely.

## Wiring in the cluster

The OKE-mode networking is enforced by **NSGs**, not security lists. The
cluster, node pool and any public Service must attach to those NSGs explicitly
— otherwise their VNICs sit on the (empty) default security list and traffic
won't flow.

```hcl
resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_id
  kubernetes_version = "v1.30.1"
  name               = "test-oke"
  vcn_id             = module.security.vcn_id

  endpoint_config {
    subnet_id            = module.security.oke.api_endpoint_subnet_id
    nsg_ids              = [module.security.oke.api_endpoint_nsg_id]
    is_public_ip_enabled = false
  }

  options {
    service_lb_subnet_ids = [module.security.oke.service_lb_subnet_id]
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
    nsg_ids = [module.security.oke.workers_nsg_id]
    placement_configs {
      availability_domain = data.oci_identity_availability_domain.ad1.name
      subnet_id           = module.security.oke.workers_subnet_id
    }
  }
}
```

For any Kubernetes Service of type `LoadBalancer`, annotate it so the
service-managed LB attaches to the LB NSG:

```yaml
metadata:
  annotations:
    oci.oraclecloud.com/oci-load-balancer-network-security-group: "<oke.service_lb_nsg_id>"
```

## Adding more NSG rules

Use the module's `additional_nsg_rules` input — extras go through the same
guardrails as `network_security_groups`, so an unsafe rule fails plan. The
`nsg` field on each entry selects which OKE NSG to attach to:
`oke_api_endpoint`, `oke_workers`, or `oke_service_lb`.

```hcl
# Inside the module "security" block in main.tf
additional_nsg_rules = {
  # CIDR source: let a monitoring subnet scrape worker node_exporter.
  "workers-from-monitoring" = {
    nsg         = "oke_workers"
    direction   = "INGRESS"
    description = "Prometheus scrape (node_exporter)"
    protocol    = "6"
    source_cidr = "10.0.50.0/24"
    port_min    = 9100
    port_max    = 9100
  }

  # Cross-NSG: an additional LB-to-workers port.
  "workers-from-lb-9090" = {
    nsg         = "oke_workers"
    direction   = "INGRESS"
    description = "LB to workers on the metrics aggregator port"
    protocol    = "6"
    source_nsg  = "oke_service_lb"
    port_min    = 9090
    port_max    = 9090
  }
}
```

Raw `oci_core_network_security_group_security_rule` resources work too but
**bypass the guardrails** — Terraform variable validation can't reach them.
Prefer `additional_nsg_rules` for rules on the OKE NSGs.

## Tear down

```bash
terraform destroy
```
