# Deployment Guide

Detailed deployment instructions for the Netskope NPA Publisher Terraform configuration on Azure.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Deployment Paths Overview](#deployment-paths-overview)
- [Path A: Local State](#path-a-local-state)
- [Path B: Remote State (Azure Storage)](#path-b-remote-state-azure-storage)
- [Configuring Variables](#configuring-variables)
- [Reviewing the Plan](#reviewing-the-plan)
- [Applying the Configuration](#applying-the-configuration)
- [Post-Deployment Verification](#post-deployment-verification)
- [Clean Up](#clean-up)

## Prerequisites

### Tool Versions

| Tool | Minimum Version | Check Command |
|---|---|---|
| Terraform | >= 0.13 | `terraform version` |
| Azure CLI | latest | `az --version` |

### Azure Requirements

- **Subscription**: Active Azure subscription with billing enabled
- **Permissions**: Contributor role or equivalent on the subscription
- **Marketplace**: Netskope NPA Publisher image terms accepted
- **SSH key**: Public key for VM access

### Netskope Requirements

- **Tenant**: Active Netskope tenant with NPA licence
- **API Token**: REST API v2 token with Infrastructure Management scope
- **Tenant URL**: Your Netskope tenant URL (e.g., `https://mytenant.goskope.com`) -- do not include `/api/v2`, the provider appends the API path automatically

### Accept Marketplace Image

```bash
az vm image terms accept \
  --publisher netskope \
  --offer netskope-npa-publisher \
  --plan npa_publisher
```

## Deployment Paths Overview

| Path | State | Best For |
|---|---|---|
| **A** | Local | Quick start, solo developer, learning |
| **B** | Remote (Azure Storage) | Teams, production, CI/CD |

## Path A: Local State

The fastest path for getting started. State is stored locally.

### Step 1: Clone and Initialise

```bash
git clone <repository-url>
cd tf-e-publisher-azure
terraform init
```

### Step 2: Configure Variables

```bash
# Sensitive values (API keys, subscription ID)
cp .env.example .env
# Edit .env with your values

# Non-sensitive values (location, naming, sizing)
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

source .env
```

### Step 3: Authenticate and Deploy

```bash
az login
terraform plan
terraform apply
```

### Step 4: Verify

```bash
terraform output
```

> **Limitation**: Local state cannot be shared with team members and has no locking. See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) for migration to remote state.

## Path B: Remote State (Azure Storage)

The recommended path for teams and production deployments.

### Step 1: Create State Backend Resources

```bash
RESOURCE_GROUP="terraform-state-rg"
STORAGE_ACCOUNT="tfstate$(openssl rand -hex 4)"
CONTAINER="tfstate"
LOCATION="uksouth"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create storage account
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --sku Standard_LRS \
  --encryption-services blob

# Create blob container
az storage container create \
  --name $CONTAINER \
  --account-name $STORAGE_ACCOUNT

# Note the values for backend configuration
echo "resource_group_name  = \"$RESOURCE_GROUP\""
echo "storage_account_name = \"$STORAGE_ACCOUNT\""
echo "container_name       = \"$CONTAINER\""
```

### Step 2: Configure the Backend

Create a `backend.tf` file:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "terraform-state-rg"
    storage_account_name = "tfstate<random>"
    container_name       = "tfstate"
    key                  = "npa-publisher.terraform.tfstate"
  }
}
```

### Step 3: Initialise with Remote Backend

```bash
terraform init
```

If you have existing local state:
```bash
terraform init -migrate-state
```

### Step 4: Configure and Deploy

```bash
cp .env.example .env
cp terraform.tfvars.example terraform.tfvars
# Edit both files with your values

source .env
az login
terraform plan
terraform apply
```

## Configuring Variables

### Two Configuration Files

**`.env`** -- Sensitive values only (API keys, subscription ID):
```bash
export ARM_SUBSCRIPTION_ID="your-subscription-id"
export TF_VAR_netskope_server_url="https://mytenant.goskope.com"
export TF_VAR_netskope_api_key="your-api-key"
```

> **Note**: `ARM_SUBSCRIPTION_ID` is an environment variable consumed directly by the AzureRM provider -- it is not a Terraform variable, so it cannot be marked `sensitive` in `variables.tf`. It is protected by being in `.env` which is excluded from Git via `.gitignore`.

**`terraform.tfvars`** -- All non-sensitive configuration:
```hcl
publisher_name = "my-npa-publisher"
gateway_count  = 2
location       = "uksouth"
admin_username = "azureuser"
admin_ssh_key  = "~/.ssh/id_rsa.pub"
```

> **Note**: Not all Azure regions support the same availability zones. The default `availability_zones = ["1", "2", "3"]` assumes three zones. If your chosen region supports fewer zones, update this variable to match (e.g. `availability_zones = ["1", "2"]`), otherwise VM creation will fail. Check zone support for your region and VM size with:
> ```bash
> az vm list-skus --location <region> --size <vm-size> --query '[].locationInfo[].zones' -o tsv
> ```

**Command-line overrides** (optional):
```bash
terraform apply -var="gateway_count=3"
```

### Security Recommendation

Never put `netskope_api_key` in `terraform.tfvars`. Keep it in `.env` which is excluded from Git via `.gitignore`.

Only `netskope_api_key` is marked `sensitive = true` in Terraform, suppressing its value from plan output.

## Reviewing the Plan

Always review the plan before applying:

```bash
terraform plan
```

### Understanding Plan Output

Key symbols:
- `+` -- Resource will be created
- `~` -- Resource will be updated in-place
- `-` -- Resource will be destroyed
- `-/+` -- Resource will be destroyed and recreated

### Saving Plans

For CI/CD or audit purposes:

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

## Applying the Configuration

```bash
terraform apply
```

Type `yes` when prompted. Terraform will create all resources in dependency order.

### Expected Resources

With `gateway_count = 2`, Terraform creates approximately:

| Resource Type | Count | Purpose |
|---|---|---|
| Resource group | 1 | Container for all resources |
| Virtual network | 1 | Network isolation |
| Subnet | 1 | Publisher subnet (spans all AZs) |
| NAT Gateway + Public IP | 2 | Outbound internet connectivity |
| NSG | 1 | Shared network security |
| Storage account | 1 | Boot diagnostics |
| Key Vault | 1 | Token storage |
| Key Vault secrets | 2 | Publisher tokens |
| Key Vault access policies | 2 | VM identity access |
| Network interfaces | 2 | VM networking |
| NSG associations | 2 | NIC-to-NSG binding |
| Linux VMs | 2 | NPA publishers |
| Netskope publishers | 2 | Netskope records |

### Handling Failures

If `terraform apply` fails partway through:

1. Read the error message
2. Fix the issue
3. Run `terraform apply` again -- Terraform picks up where it left off

## Post-Deployment Verification

### 1. Terraform Outputs

```bash
terraform output
```

### 2. Azure Resources

```bash
az vm list \
  --resource-group PRD-NPA-rg \
  --query '[].{name:name, status:powerState, zone:zones[0]}' \
  --output table --show-details
```

### 3. Netskope UI

1. Log in to Netskope tenant
2. Navigate to **Settings > Security Cloud Platform > Publishers**
3. Verify publisher status is **Connected**

### 4. Drift Detection

```bash
terraform plan
# "No changes" means infrastructure matches configuration
```

## Clean Up

### Destroy NPA Infrastructure

```bash
terraform destroy
```

This removes all Terraform-managed resources:
- VMs, NICs, NSG
- Key Vault and secrets
- VNet, subnet, NAT Gateway
- Netskope publishers
- Resource group

### Verify Cleanup

```bash
terraform state list
# Should return empty

az group show --name PRD-NPA-rg 2>/dev/null || echo "Resource group deleted"
```

## Additional Resources

- [QUICKSTART.md](QUICKSTART.md) -- Fast deployment
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) -- Remote state setup
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) -- Common issues
- [OPERATIONS.md](OPERATIONS.md) -- Day-2 operations
