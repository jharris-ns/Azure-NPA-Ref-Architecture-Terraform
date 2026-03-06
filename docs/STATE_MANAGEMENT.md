# Terraform State Management

Guide to managing Terraform state for the NPA Publisher deployment on Azure.

## Table of Contents

- [What is Terraform State?](#what-is-terraform-state)
- [Local State](#local-state)
- [Remote State with Azure Storage](#remote-state-with-azure-storage)
- [Configuring the Azure Backend](#configuring-the-azure-backend)
- [Migration: Local to Remote](#migration-local-to-remote)
- [State Security](#state-security)
- [State Operations](#state-operations)
- [Team Workflow](#team-workflow)
- [Disaster Recovery](#disaster-recovery)
- [Cost](#cost)

## What is Terraform State?

Terraform state is a JSON file that maps your configuration to real-world infrastructure. Every time you run `terraform apply`, Terraform records what it created so it can manage those resources on future runs.

### Sensitive Data in State

Terraform state stores resource attributes in plain text. For this project, state contains:

- **Netskope API key** (from provider configuration)
- **Netskope publisher registration tokens** (from `netskope_publishers` and Key Vault secrets)
- **VM metadata** (private IPs, managed identity principal IDs)
- **Key Vault configuration**

> **Warning**: Anyone who can read your state file can see your Netskope API key and registration tokens. Treat state files with the same care as credentials.

## Local State

### Default Behaviour

By default, Terraform stores state in `terraform.tfstate` in the working directory.

### When Local State is Appropriate

- Learning and experimentation
- Solo developer projects
- Ephemeral environments

### Security Precautions

The `.gitignore` already excludes state files:
```gitignore
*.tfstate
*.tfstate.backup
```

Additionally:
```bash
chmod 600 terraform.tfstate
```

### Limitations

| Limitation | Impact |
|---|---|
| No encryption at rest | Secrets visible in plain text |
| No locking | Concurrent runs can corrupt state |
| No versioning | Cannot recover from mistakes |
| No sharing | Team members cannot collaborate |

## Remote State with Azure Storage

### Why Azure Storage?

| Feature | Benefit |
|---|---|
| **Blob storage** | Durable state file storage |
| **Blob leasing** | State locking (prevents concurrent modifications) |
| **Encryption** | State encrypted at rest (Azure Storage Service Encryption) |
| **Versioning** | Recover previous state versions (if blob versioning enabled) |

### How It Works

```
terraform apply
    |
    |- 1. Acquire blob lease (locking)
    |- 2. Download current state blob
    |- 3. Plan and apply changes
    |- 4. Upload new state blob (encrypted at rest)
    '- 5. Release blob lease
```

## Configuring the Azure Backend

### Step 1: Create Backend Resources

```bash
RESOURCE_GROUP="terraform-state-rg"
STORAGE_ACCOUNT="tfstate$(openssl rand -hex 4)"
CONTAINER="tfstate"
LOCATION="uksouth"

az group create --name $RESOURCE_GROUP --location $LOCATION

az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --sku Standard_LRS \
  --encryption-services blob \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage container create \
  --name $CONTAINER \
  --account-name $STORAGE_ACCOUNT
```

### Step 2: Create backend.tf

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

### Step 3: Initialise

```bash
terraform init
```

### Environment-Specific Key Paths

Use different `key` values for environment isolation:

```hcl
# Production
key = "npa-publisher/production.terraform.tfstate"

# Staging
key = "npa-publisher/staging.terraform.tfstate"
```

## Migration: Local to Remote

```bash
# 1. Verify current state
terraform state list

# 2. Add backend.tf configuration

# 3. Initialise with migration
terraform init -migrate-state
# Type 'yes' when prompted

# 4. Verify
terraform state list
terraform plan  # Should show "No changes"

# 5. Clean up local state
rm terraform.tfstate terraform.tfstate.backup
```

## State Security

### Registration Tokens in State

```
netskope_publishers.npa["1"]
  |- name  = "my-publisher"
  '- token = "eyJhbGciOiJSUz..." (sensitive)

azurerm_key_vault_secret.publisher_token["1"]
  |- name  = "npa-publisher-token-1"
  '- value = "eyJhbGciOiJSUz..." (sensitive)
```

**Mitigations:**
1. **Tokens are single-use**: Once consumed, they cannot be reused
2. **Storage encryption**: Azure Storage encrypts at rest
3. **Key Vault**: Tokens are also stored encrypted in Key Vault
4. **Access control**: Storage account access restricted by Azure RBAC
5. **Sensitive marking**: Variables and outputs marked `sensitive` suppress plan output

### Recommended Security Settings

- **Storage account**: Disable public blob access, require TLS 1.2
- **RBAC**: Use Azure RBAC instead of storage account keys where possible
- **Network rules**: Restrict storage account access to specific networks/IPs
- **Soft delete**: Enable blob soft delete for recovery

## State Operations

### Listing Resources

```bash
terraform state list

# Example output:
# azurerm_linux_virtual_machine.vm["1"]
# azurerm_linux_virtual_machine.vm["2"]
# azurerm_key_vault.kv
# netskope_publishers.npa["1"]
# netskope_publishers.npa["2"]
```

### Showing Resource Details

```bash
terraform state show 'azurerm_linux_virtual_machine.vm["1"]'
```

### Removing Resources from State

```bash
# Stop managing a resource (resource continues to exist in Azure)
terraform state rm 'azurerm_linux_virtual_machine.vm["1"]'
```

### Replacing Resources

```bash
terraform apply -replace='azurerm_linux_virtual_machine.vm["1"]'
```

### Unlocking State

If a Terraform process crashes, the blob lease may remain:

```bash
terraform force-unlock LOCK_ID
```

> **Warning**: Only force-unlock when certain no other process is running.

## Team Workflow

### How Locking Works

Azure Storage uses blob leasing for state locking. When someone runs `terraform apply`:

1. Terraform acquires a lease on the state blob
2. If already leased, it shows who holds the lock
3. The lease is released when the operation completes

### CI/CD Considerations

**Pipeline best practices:**

1. Use the same backend as developers
2. Serialise applies (one pipeline at a time)
3. Plan in PR, apply on merge
4. Store plan files for audit

```bash
# CI/CD pipeline
terraform init
terraform plan -out=tfplan
# (human reviews plan)
terraform apply tfplan
```

## Disaster Recovery

### Recovering with Blob Versioning

If blob versioning is enabled on the storage account:

```bash
# List blob versions
az storage blob list \
  --account-name <storage-account> \
  --container-name tfstate \
  --prefix npa-publisher \
  --include v \
  --query '[].{name:name, version:versionId, modified:properties.lastModified}' \
  --output table
```

### Manual Backup

```bash
terraform state pull > state-backup-$(date +%Y%m%d-%H%M%S).json
```

### Rebuilding State

If state is completely lost but infrastructure exists:

```bash
terraform init
terraform import 'azurerm_resource_group.rg' /subscriptions/<sub>/resourceGroups/PRD-NPA-rg
terraform import 'azurerm_virtual_network.vnet' /subscriptions/<sub>/resourceGroups/PRD-NPA-rg/providers/Microsoft.Network/virtualNetworks/PRD-NPA-vnet
terraform import 'azurerm_linux_virtual_machine.vm["1"]' /subscriptions/<sub>/resourceGroups/PRD-NPA-rg/providers/Microsoft.Compute/virtualMachines/PRD-NPA-1-vm
# ... import remaining resources

terraform plan
# Fix any configuration differences
```

## Cost

The state backend costs approximately **$0.10-0.50/month**:

| Service | Cost | Details |
|---|---|---|
| **Storage Account** | ~$0.02/month | LRS, state files are small (<1 MB) |
| **Blob operations** | ~$0.01/month | Read/write operations are infrequent |
| **Resource Group** | Free | No cost |

**Total: ~$0.03/month**

## Additional Resources

- [ARCHITECTURE.md](ARCHITECTURE.md) -- Architecture overview
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) -- Deployment paths
- [Terraform Azure Backend Documentation](https://developer.hashicorp.com/terraform/language/settings/backends/azurerm)
- [Azure Storage Security](https://learn.microsoft.com/en-us/azure/storage/common/storage-security-guide)
