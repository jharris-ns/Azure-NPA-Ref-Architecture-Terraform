# NPA Publisher - Multi-AZ Deployment on Azure (Terraform)

Automated deployment of Netskope Private Access (NPA) Publishers on Azure using Terraform with multi-AZ redundancy, Key Vault token management, and the Netskope Terraform provider for publisher lifecycle management.

## Overview

This solution provides a highly available deployment of NPA Publishers with automatic registration to your Netskope tenant. It uses the [Netskope Terraform provider](https://registry.terraform.io/providers/netskopeoss/netskope/latest) to create publishers, generate registration tokens, and launch Azure VMs that self-register on boot via cloud-init. Multi-AZ deployment distributes publishers across availability zones for production redundancy.

## Documentation

This project includes comprehensive documentation for deployment, operations, and troubleshooting:

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** — Detailed architecture overview covering network design, security layers, high availability, and Azure Well-Architected Framework alignment
- **[QUICKSTART.md](docs/QUICKSTART.md)** — Get started with a guided quick deployment
- **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)** — Complete deployment instructions with all configuration options and multiple deployment paths
- **[STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md)** — Terraform state management: local vs. remote, Azure Storage backend setup, migration, and security
- **[BASTION_ACCESS.md](docs/BASTION_ACCESS.md)** — Azure Bastion deployment and SSH access to publisher instances
- **[DEVOPS-NOTES.md](docs/DEVOPS-NOTES.md)** — Technical deep-dive into Terraform patterns, provider internals, `for_each`, cloud-init, and pre-commit hooks
- **[OPERATIONS.md](docs/OPERATIONS.md)** — Day-2 operational procedures: upgrades, scaling, rotation, replacement, and monitoring
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — Common issues and solutions with diagnostic commands

**Quick Links:**
- Want to understand the architecture? See **[ARCHITECTURE.md](docs/ARCHITECTURE.md)**
- New to the project? Start with **[QUICKSTART.md](docs/QUICKSTART.md)**
- Need to deploy? See **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)**
- Setting up remote state? See **[STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md)**
- Need SSH access? See **[BASTION_ACCESS.md](docs/BASTION_ACCESS.md)**
- Already deployed? Check **[OPERATIONS.md](docs/OPERATIONS.md)**
- Having issues? See **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**

## Architecture

![NPA Publisher Azure Architecture](images/arch.png.old)

## How It Works

### On `terraform apply`

1. **Netskope provider creates publishers** in your Netskope tenant via the REST API
2. **Netskope provider generates registration tokens** (one per publisher, single-use)
3. **Tokens stored in Key Vault** — each token is stored as a Key Vault secret
4. **VMs launch with cloud-init** — bootstrap script uses the VM's managed identity to fetch its token from Key Vault
5. **`npa_publisher_wizard`** runs on each instance, consuming the token and establishing an outbound TLS connection to Netskope NewEdge
6. **Publishers appear as "Connected"** in the Netskope admin console

### On `terraform destroy`

Terraform enforces correct destroy ordering via dependencies:

1. **Key Vault access policies removed** — VMs lose secret access
2. **VMs terminated** — disconnects publishers from Netskope
3. **Key Vault secrets deleted** — tokens purged
4. **Publisher records deleted** from Netskope via the API
5. **Network resources cleaned up** — NICs, NSG, NAT Gateway, VNet, resource group

## Security Design

- **No inbound NSG rules** — Publishers only initiate outbound connections (zero inbound attack surface)
- **No public IPs** on VMs — all instances are in a private subnet
- **Managed identity** — VMs authenticate to Key Vault via system-assigned identity (no credentials stored)
- **Key Vault token storage** — Registration tokens stored in Key Vault, not embedded in `custom_data`
- **Scoped access** — Each VM can only read its own token (Get-only permissions)
- **NAT Gateway** — Predictable outbound connectivity via static public IP
- **Azure Bastion** — Recommended for remote access (no SSH port exposure). See [BASTION_ACCESS.md](docs/BASTION_ACCESS.md)
- **Pre-commit scanning** — checkov, tflint, and gitleaks catch issues before commit

## Getting Started

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 0.13
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- Azure subscription with [required permissions](#azure-permissions) (see below)
- Netskope API key with **Infrastructure Management** scope
- RSA SSH public key (Azure does not support ed25519)
- [Netskope Publisher marketplace image](https://azuremarketplace.microsoft.com/) terms accepted

### Accept Marketplace Image

```bash
az vm image terms accept \
  --publisher netskope \
  --offer netskope-npa-publisher \
  --plan npa_publisher
```

### Quick Deploy

```bash
# 1. Clone and configure
git clone https://github.com/jharris-ns/Azure-NPA-Ref-Architecture-Terraform.git
cd Azure-NPA-Ref-Architecture-Terraform/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 2. Set sensitive credentials
export ARM_SUBSCRIPTION_ID="your-subscription-id"
export TF_VAR_netskope_server_url="https://mytenant.goskope.com"
export TF_VAR_netskope_api_key="your-api-key"

# 3. Deploy
az login
terraform init
terraform plan
terraform apply

# 4. Verify
terraform output publisher_names
terraform output private_ip_addresses
# Check Netskope UI: Settings → Security Cloud Platform → Publishers → verify "Connected"
```

For detailed instructions, see **[QUICKSTART.md](docs/QUICKSTART.md)** or **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)**.

## Project Structure

```
Azure-NPA-Ref-Architecture-Terraform/
├── README.md                            # This file
├── LICENSE                              # License
├── CLAUDE.md                            # Project guidelines for AI-assisted development
│
├── docs/                                # Comprehensive documentation
│   ├── ARCHITECTURE.md
│   ├── QUICKSTART.md
│   ├── DEPLOYMENT_GUIDE.md
│   ├── STATE_MANAGEMENT.md
│   ├── BASTION_ACCESS.md
│   ├── DEVOPS-NOTES.md
│   ├── OPERATIONS.md
│   └── TROUBLESHOOTING.md
│
├── images/                              # Architecture diagrams and screenshots
│   ├── arch.png
│   └── npa-token.png
│
├── terraform/                           # All Terraform code
│   ├── variables.tf                     # Input variables
│   ├── main.tf                          # Main entrypoint
│   ├── outputs.tf                       # Output values (IPs, names, zones)
│   ├── providers.tf                     # AzureRM and Netskope provider configuration
│   ├── version.tf                       # Terraform and provider version constraints
│   ├── data.tf                          # Data sources (client config)
│   ├── local.tf                         # Computed values (instances map, AZ distribution)
│   │
│   ├── npa.tf                           # Netskope publisher resources
│   ├── vm.tf                            # Linux VMs with managed identity and cloud-init
│   ├── keyvault.tf                      # Key Vault, access policies, token secrets
│   ├── network.tf                       # VNet, subnet, NAT Gateway
│   ├── nics.tf                          # Network interfaces
│   ├── nsg.tf                           # Network security group
│   ├── rg.tf                            # Resource group
│   ├── storage.tf                       # Boot diagnostics storage account
│   │
│   ├── terraform.tfvars.example         # Example variable values
│   └── scripts/
│       └── bootstrap.tpl               # Cloud-init template (Key Vault token retrieval)
│
├── .github/workflows/                   # CI/CD
│   ├── lint.yml                         # Terraform fmt, validate, tflint
│   └── security.yml                     # Gitleaks, checkov
│
├── .pre-commit-config.yaml              # Pre-commit hooks
├── .tflint.hcl                          # TFLint configuration (azurerm plugin)
└── .gitignore                           # Git ignore rules
```

## Variable Reference

### Required (set via environment variables)

| Variable | Description | Set via |
|---|---|---|
| `ARM_SUBSCRIPTION_ID` | Azure subscription ID | `export ARM_SUBSCRIPTION_ID=...` |
| `netskope_server_url` | Netskope tenant URL (e.g. `https://mytenant.goskope.com`) | `export TF_VAR_netskope_server_url=...` |
| `netskope_api_key` | Netskope API key (sensitive) | `export TF_VAR_netskope_api_key=...` |

### Required (set in terraform.tfvars)

| Variable | Description |
|---|---|
| `publisher_name` | Base name for publishers |
| `admin_username` | VM local admin username |
| `admin_ssh_key` | Path to RSA SSH public key |

### Optional (with defaults)

| Variable | Default | Description |
|---|---|---|
| `location` | `uksouth` | Azure region |
| `gateway_count` | `2` | Number of publisher instances |
| `vm_size` | `Standard_B2ms` | VM size |
| `vnet_address_space` | `10.0.0.0/16` | VNet CIDR block |
| `snet_address_prefix` | `10.0.1.0/24` | Subnet CIDR block |
| `availability_zones` | `["1", "2", "3"]` | AZs to distribute across |
| `env_prefix` | `PRD` | Environment prefix for naming |
| `vm_prefix` | `NPA` | VM prefix for naming |

## Azure Permissions

The simplest option is to assign the built-in **Contributor** role at the subscription scope:

```bash
az role assignment create \
  --assignee "<service-principal-or-user-object-id>" \
  --role "Contributor" \
  --scope "/subscriptions/<your-subscription-id>"
```

For production deployments, use a custom role with least-privilege permissions instead:

```bash
az role definition create --role-definition '{
  "Name": "NPA Publisher Deployer",
  "Description": "Least-privilege role for deploying NPA Publisher infrastructure via Terraform",
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/subscriptions/resourceGroups/delete",

    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/write",
    "Microsoft.Network/virtualNetworks/delete",
    "Microsoft.Network/virtualNetworks/subnets/read",
    "Microsoft.Network/virtualNetworks/subnets/write",
    "Microsoft.Network/virtualNetworks/subnets/delete",
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.Network/networkSecurityGroups/read",
    "Microsoft.Network/networkSecurityGroups/write",
    "Microsoft.Network/networkSecurityGroups/delete",
    "Microsoft.Network/networkSecurityGroups/join/action",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Network/networkInterfaces/write",
    "Microsoft.Network/networkInterfaces/delete",
    "Microsoft.Network/networkInterfaces/join/action",
    "Microsoft.Network/publicIPAddresses/read",
    "Microsoft.Network/publicIPAddresses/write",
    "Microsoft.Network/publicIPAddresses/delete",
    "Microsoft.Network/publicIPAddresses/join/action",
    "Microsoft.Network/natGateways/read",
    "Microsoft.Network/natGateways/write",
    "Microsoft.Network/natGateways/delete",
    "Microsoft.Network/natGateways/join/action",

    "Microsoft.KeyVault/vaults/read",
    "Microsoft.KeyVault/vaults/write",
    "Microsoft.KeyVault/vaults/delete",
    "Microsoft.KeyVault/vaults/accessPolicies/write",
    "Microsoft.KeyVault/vaults/secrets/read",
    "Microsoft.KeyVault/vaults/secrets/write",
    "Microsoft.KeyVault/vaults/secrets/delete",

    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Storage/storageAccounts/delete",
    "Microsoft.Storage/storageAccounts/listKeys/action",

    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/write",
    "Microsoft.Compute/virtualMachines/delete",
    "Microsoft.Compute/disks/read",
    "Microsoft.Compute/disks/write",
    "Microsoft.Compute/disks/delete",

    "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
    "Microsoft.Authorization/roleAssignments/read"
  ],
  "AssignableScopes": [
    "/subscriptions/<your-subscription-id>"
  ]
}'
```

Then assign the role to the Terraform service principal or user:

```bash
az role assignment create \
  --assignee "<service-principal-or-user-object-id>" \
  --role "NPA Publisher Deployer" \
  --scope "/subscriptions/<your-subscription-id>"
```

## Limitations

- No auto scaling — fixed capacity per deployment
- Instance failure requires manual replacement (`terraform apply -replace`)
- Registration tokens are single-use — replacing a VM generates a new token
- Publishers self-update, but marketplace image changes require VM replacement
- Azure only supports RSA SSH keys (not ed25519)
- Not all Azure regions support 3 availability zones — set `availability_zones` to match your region

## Additional Resources

### External Resources
- [Netskope REST API v2](https://docs.netskope.com/en/rest-api-v2-overview-312207.html)
- [Netskope Terraform Provider](https://registry.terraform.io/providers/netskopeoss/netskope/latest)
- [Terraform AzureRM Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/)
- [Azure Bastion Documentation](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview)

## Support

Netskope-provided scripts in this and other GitHub projects do not fall under the regular Netskope technical support scope and are not supported by Netskope support services.

## License

See [LICENSE](LICENSE) for details.
