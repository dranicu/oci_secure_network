# Example — general-purpose VCN with bastion

Showcases the [`security`](../../modules/security/) module in `mode = "general"`:

- A VCN (`10.0.0.0/16`) with two private subnets - one for the bastion, one
  for application instances - plus a NAT Gateway for egress and a Service
  Gateway for OCI services.
- An NSG on the application tier that allows SSH **only from the bastion
  subnet** and outbound HTTPS for package updates.
- An OCI managed Bastion in the bastion subnet, with its client allow-list
  pinned to a single operator `/32`.
- Optionally, a managed-SSH session against an existing compute instance.

The Bastion is the only inbound path. There is no Internet Gateway pointed
at any workload subnet.

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

To also create a managed-SSH session against an existing instance, set
`target_resource_id`:

```bash
terraform apply -var target_resource_id=ocid1.instance.oc1..yyyyy
```

The instance must already exist in the app subnet (or any subnet reachable
from the bastion) and have the Oracle Cloud Agent's Bastion plugin enabled.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `compartment_id` | — | Compartment OCID to deploy into. |
| `home_region` | — | Tenancy home region (Identity → Region Management). IAM writes go here. |
| `operator_cidr` | — | Single-host `/32` allowed to reach the bastion. Required. Get yours with `curl -s ifconfig.me`. |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | Public key the bastion session will authorise. |
| `target_resource_id` | `null` | OCID of an existing instance to create a session against; null skips the session. |

## Outputs

| Output | Description |
|--------|-------------|
| `vcn_id` | VCN OCID. |
| `bastion_subnet_id` / `app_subnet_id` | Subnet OCIDs. |
| `bastion_id` | Bastion OCID. |
| `bastion_session_id` | Session OCID, or null. |
| `ssh_command` | The `ssh -o ProxyCommand=...` line the bastion returns. Copy verbatim. |

## Adding more NSG rules

Use the module's `additional_nsg_rules` input — extras go through the same
guardrails as `network_security_groups`, so an unsafe rule fails plan.

```hcl
# Inside the module "security" block in main.tf
additional_nsg_rules = {
  "app-from-bastion-8080" = {
    nsg         = "app"
    direction   = "INGRESS"
    description = "Operator debug port from the bastion subnet"
    protocol    = "6"
    source_cidr = "10.0.1.0/24"
    port_min    = 8080
    port_max    = 8080
  }
}
```

A brand-new NSG (one the module doesn't manage) still goes the raw-resource
route — point its `vcn_id` at `module.security.vcn_id`:

```hcl
resource "oci_core_network_security_group" "monitoring" {
  compartment_id = var.compartment_id
  vcn_id         = module.security.vcn_id
  display_name   = "monitoring-nsg"
}
```

Raw `oci_core_network_security_group_security_rule` resources work too but
**bypass the guardrails** — Terraform variable validation can't reach them.
Prefer `additional_nsg_rules` for rules on NSGs the module already created.

## Connecting

After apply, if a session was created:

```bash
$(terraform output -raw ssh_command)
```

If no session was created (the default), use the OCI CLI ad-hoc:

```bash
oci bastion session create-managed-ssh \
  --bastion-id "$(terraform output -raw bastion_id)" \
  --target-resource-id ocid1.instance.oc1..yyyyy \
  --target-os-username opc \
  --ssh-public-key-file ~/.ssh/id_rsa.pub
```

## Tear down

```bash
terraform destroy
```
