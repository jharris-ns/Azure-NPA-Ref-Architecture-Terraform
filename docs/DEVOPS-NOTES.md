# Terraform Technical Notes

Technical deep-dive into the Terraform patterns, Netskope provider integration, and Azure-specific design used in this project.

## Table of Contents

- [Netskope Terraform Provider](#netskope-terraform-provider)
- [Publisher Registration Flow](#publisher-registration-flow)
- [for_each Pattern](#for_each-pattern)
- [Key Vault Token Delivery](#key-vault-token-delivery)
- [Bootstrap Template](#bootstrap-template)
- [Resource Dependencies](#resource-dependencies)
- [Lifecycle Rules](#lifecycle-rules)
- [Provider Version Constraints](#provider-version-constraints)

## Netskope Terraform Provider

### Provider Configuration

The Netskope provider is configured in `providers.tf`:

```hcl
provider "netskope" {
  baseurl  = var.netskope_server_url
  apitoken = var.netskope_api_key
}
```

### Authentication

The provider authenticates using a REST API v2 token. Both values are set in the `.env` file:

```bash
export TF_VAR_netskope_server_url="https://mytenant.goskope.com"
export TF_VAR_netskope_api_key="your-api-key"
```

Only `netskope_api_key` is marked `sensitive = true` in Terraform. The server URL is not sensitive but is kept in `.env` for consistency with the API key.

The API key requires the **Infrastructure Management** scope in Netskope:
1. Netskope UI > **Settings > Tools > REST API v2**
2. Create or select a token
3. Enable **Infrastructure Management** (read/write)

### Resources Used

| Resource | File | Purpose |
|---|---|---|
| `netskope_publishers` | `npa.tf` | Creates publisher records in Netskope tenant and generates registration tokens |

### API Calls During Apply

When `terraform apply` runs, the Netskope provider makes these API calls:

1. **Create publisher**: `POST /api/v2/infrastructure/publishers`
   - Creates a named publisher record
   - Returns publisher ID and registration token

2. **Read publisher** (during plan/refresh): `GET /api/v2/infrastructure/publishers/{id}`
   - Reads current publisher state for comparison

3. **Delete publisher** (during destroy): `DELETE /api/v2/infrastructure/publishers/{id}`
   - Removes publisher from Netskope tenant

## Publisher Registration Flow

The end-to-end flow from Terraform to a connected publisher:

```
1. Terraform creates netskope_publishers (for_each)
   '- API call to Netskope -> publisher record + token created

2. Terraform stores token in Azure Key Vault (for_each)
   '- azurerm_key_vault_secret.publisher_token (encrypted at rest)

3. Terraform creates azurerm_linux_virtual_machine (for_each)
   '- VM launches in private subnet with managed identity
   '- custom_data contains bootstrap script with vault_name and secret_name
   '- No token in custom_data (only Key Vault reference)

4. VM boots and cloud-init runs bootstrap.tpl
   |- Fetches access token from IMDS using managed identity
   |- Retrieves publisher token from Key Vault
   '- Runs /home/ubuntu/npa_publisher_wizard -token <token>

5. Terraform creates Key Vault access policy for the VM
   '- azurerm_key_vault_access_policy.vm_access grants Get permission

6. Publisher wizard registers with Netskope
   |- Token consumed (single-use)
   '- Outbound TLS connection to NewEdge established

7. Publisher appears as "Connected" in Netskope UI
```

### Security Implications

**Token in Key Vault:**

The registration token is stored in Azure Key Vault (encrypted at rest with Azure-managed keys). It is fetched at runtime by the VM's managed identity. This means:
- The token is **not** visible in VM custom_data or instance metadata
- The token is encrypted at rest in Key Vault
- The token is stored in Terraform state (encrypt state for production use)
- Only the specific VM's managed identity can read its token

**Mitigations:**
- **Key Vault encryption**: Tokens encrypted at rest with Azure platform keys
- **Managed identity access**: Each VM can only read its own token via scoped access policies
- **Single-use token**: Once the publisher registers, the token cannot be reused
- **No SSH exposure**: Private subnet with no inbound NSG rules; use Azure Bastion for access
- **NAT Gateway egress**: Outbound connectivity without public IPs on VMs

## for_each Pattern

### The instances Local

The `local.instances` map is the core of the multi-instance pattern:

```hcl
locals {
  instances = {
    for i in range(var.gateway_count) :
    tostring(i + 1) => {
      index = i
      name  = i == 0 ? var.publisher_name : "${var.publisher_name}-${i + 1}"
      zone  = length(var.availability_zones) > 0 ? var.availability_zones[i % length(var.availability_zones)] : null
    }
  }
}
```

With `publisher_name = "my-pub"` and `gateway_count = 3`, this generates:

```hcl
{
  "1" = { index = 0, name = "my-pub",   zone = "1" }
  "2" = { index = 1, name = "my-pub-2", zone = "2" }
  "3" = { index = 2, name = "my-pub-3", zone = "3" }
}
```

### State Addressing

Resources using `for_each` are addressed by their map key:

```
netskope_publishers.npa["1"]
netskope_publishers.npa["2"]
netskope_publishers.npa["3"]

azurerm_linux_virtual_machine.vm["1"]
azurerm_linux_virtual_machine.vm["2"]
azurerm_linux_virtual_machine.vm["3"]
```

### Why for_each Over count

**The count problem:**
```hcl
# With count, resources are indexed by position:
resource "azurerm_linux_virtual_machine" "vm" {
  count = 3
  # azurerm_linux_virtual_machine.vm[0], [1], [2]
}

# Removing index 1 shifts everything:
# [0] stays, [1] becomes the OLD [2], [2] is destroyed
# This destroys and recreates the wrong instance!
```

**The for_each solution:**
```hcl
# With for_each, resources are indexed by key:
resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.instances
  # azurerm_linux_virtual_machine.vm["1"], ["2"], ["3"]
}

# Removing "2" only affects that specific resource:
# ["1"] stays, ["2"] is destroyed, ["3"] stays
```

### Adding/Removing Publishers

**Add a publisher** -- increase `gateway_count` in `terraform.tfvars`:
```hcl
gateway_count = 3  # Was 2
```
```bash
terraform apply
# Only creates new resources for instance "3"
# Existing instances untouched
```

**Remove a publisher** -- decrease `gateway_count` in `terraform.tfvars`:
```hcl
gateway_count = 1  # Was 2
```
```bash
terraform apply
# Only destroys resources for instance "2"
# Existing instance untouched
```

### AZ Distribution

Instances are distributed across availability zones using modulo arithmetic:

```hcl
zone = length(var.availability_zones) > 0 ? var.availability_zones[i % length(var.availability_zones)] : null
```

With 3 zones and 4 publishers:

| Publisher | Index | Index % 3 | Zone |
|---|---|---|---|
| my-pub | 0 | 0 | 1 |
| my-pub-2 | 1 | 1 | 2 |
| my-pub-3 | 2 | 2 | 3 |
| my-pub-4 | 3 | 0 | 1 |

For regions without zone support, set `availability_zones = []` and the `zone` parameter will be `null`.

## Key Vault Token Delivery

### Why Key Vault Instead of custom_data

The original approach embedded the registration token directly in `custom_data`:

```hcl
# INSECURE - token exposed in:
# - Terraform plan output
# - Azure portal (VM custom_data)
# - Cloud-init logs
# - Instance metadata service
custom_data = base64encode(templatefile("bootstrap.tpl", { token = netskope_publishers.npa.token }))
```

The Key Vault approach passes only a vault reference in `custom_data`:

```hcl
# SECURE - only vault name and secret name in custom_data
custom_data = base64encode(templatefile("bootstrap.tpl", {
  vault_name  = azurerm_key_vault.kv.name
  secret_name = azurerm_key_vault_secret.publisher_token[each.key].name
}))
```

### Access Policy Design

The Key Vault uses two types of access policies:

**Deployer policy (inline in Key Vault resource):**
```hcl
access_policy {
  object_id          = data.azurerm_client_config.current.object_id
  secret_permissions = ["Set", "Get", "Delete", "Purge"]
}
```

**VM policies (separate resources with for_each):**
```hcl
resource "azurerm_key_vault_access_policy" "vm_access" {
  for_each  = local.instances
  object_id = azurerm_linux_virtual_machine.vm[each.key].identity[0].principal_id
  secret_permissions = ["Get"]
}
```

Each VM can only `Get` secrets -- it cannot list, set, or delete them.

## Bootstrap Template

### Template File

The bootstrap script is in `scripts/bootstrap.tpl`:

```bash
#!/bin/bash
set -e

# Fetch access token from IMDS using the VM's managed identity
access_token=$(curl -s -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | jq -r '.access_token')

# Retrieve the publisher token from Key Vault
token=$(curl -s -H "Authorization: Bearer $access_token" \
  "https://${vault_name}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
  | jq -r '.value')

# Register the publisher
sudo /home/ubuntu/npa_publisher_wizard -token "$token"

# Clear sensitive variables
unset access_token token
```

### Template Rendering

The template is rendered per-instance using `templatefile()`:

```hcl
custom_data = base64encode(templatefile("${path.root}/scripts/bootstrap.tpl", {
  vault_name  = azurerm_key_vault.kv.name
  secret_name = azurerm_key_vault_secret.publisher_token[each.key].name
}))
```

### How IMDS Authentication Works

1. The VM has a **system-assigned managed identity** (enabled via `identity { type = "SystemAssigned" }`)
2. The bootstrap script calls the Azure Instance Metadata Service (IMDS) at `169.254.169.254`
3. IMDS returns an OAuth2 access token scoped to `https://vault.azure.net`
4. The script uses this token to authenticate to Key Vault and retrieve the publisher token
5. No credentials are stored on disk or passed via custom_data

### base64encode

Azure VM custom_data must be base64-encoded:

```hcl
custom_data = base64encode(templatefile(...))
```

Without `base64encode()`, Azure would reject the custom_data.

## Resource Dependencies

### Implicit Dependency Graph

Terraform automatically determines resource creation order based on references:

```
azurerm_resource_group.rg
  |- azurerm_virtual_network.vnet
  |    '- azurerm_subnet.snet
  |         |- azurerm_subnet_nat_gateway_association.snet_nat_assoc
  |         '- azurerm_network_interface.nic (for_each)
  |- azurerm_nat_gateway.nat
  |    '- azurerm_nat_gateway_public_ip_association.nat_pip_assoc
  |- azurerm_public_ip.nat_pip
  |- azurerm_network_security_group.nsg
  |- azurerm_storage_account.stg
  '- azurerm_key_vault.kv

netskope_publishers.npa (for_each)
  '- azurerm_key_vault_secret.publisher_token (for_each)

azurerm_network_interface.nic (for_each)  -|
azurerm_key_vault_secret.publisher_token  -|
azurerm_storage_account.stg               -|-> azurerm_linux_virtual_machine.vm (for_each)
                                                '- azurerm_key_vault_access_policy.vm_access (for_each)
```

### External Dependencies

1. **Netskope Cloud**: Publisher management API must be reachable during `terraform apply`
2. **Azure Marketplace**: NPA Publisher image must be accepted
3. **Azure Services**: Compute, Network, Key Vault must be available in the target region
4. **Internet Connectivity**: Required for Netskope communication from publishers (via NAT Gateway)

## Lifecycle Rules

### ignore_changes

The VMs use `ignore_changes` to prevent unintended replacements:

```hcl
lifecycle {
  ignore_changes = [custom_data]
}
```

**Why ignore custom_data changes?**
- Custom data changes force VM replacement (destroy + recreate)
- Existing publishers should not be disrupted by template changes
- The bootstrap script only needs to run once during initial registration

The Netskope publishers also ignore token changes:

```hcl
lifecycle {
  ignore_changes = [token]
}
```

**Why ignore token changes?**
- Tokens are generated once at creation
- Subsequent reads may return different values from the API
- The original token is what was stored in Key Vault

### Intentional Replacement

When you need to replace an instance (e.g., to apply a new image), you must also replace the Netskope publisher record because registration tokens are single-use:

```bash
# Replace a specific publisher (all related resources)
terraform apply \
  -replace='netskope_publishers.npa["1"]' \
  -replace='azurerm_key_vault_secret.publisher_token["1"]' \
  -replace='azurerm_linux_virtual_machine.vm["1"]'
```

### When to Use -replace

| Scenario | Command |
|---|---|
| Instance is unhealthy | `terraform apply -replace='netskope_publishers.npa["1"]' -replace='azurerm_key_vault_secret.publisher_token["1"]' -replace='azurerm_linux_virtual_machine.vm["1"]'` |
| Need fresh image | Same as above (new instance needs new token) |
| Replace everything | `terraform destroy && terraform apply` |

## Provider Version Constraints

### Version Specification

From `version.tf`:

```hcl
terraform {
  required_version = ">= 0.13.0"
  required_providers {
    azurerm  = "~> 3.11.0"
    null     = "~> 3.1.1"
    random   = "~> 3.3.2"
    local    = "~> 2.2.3"
    netskope = {
      source  = "netskopeoss/netskope"
      version = "0.2.1"
    }
  }
}
```

### Version Constraint Syntax

| Constraint | Meaning |
|---|---|
| `>= 0.13.0` | Version 0.13.0 or later |
| `~> 3.11.0` | Version 3.11.x (any patch, not 3.12.0) |
| `= 0.2.1` | Exactly version 0.2.1 |

### Lock File

The `.terraform.lock.hcl` file pins exact provider versions and checksums. It ensures all team members and CI/CD use identical provider versions.

```bash
# Update lock file after changing version constraints
terraform init -upgrade
```

## Additional Resources

- [ARCHITECTURE.md](ARCHITECTURE.md) -- Architecture overview
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) -- State management guide
- [OPERATIONS.md](OPERATIONS.md) -- Day-2 operations
- [Netskope Terraform Provider](https://registry.terraform.io/providers/netskopeoss/netskope/latest/docs)
- [Terraform for_each Documentation](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each)
