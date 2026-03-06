# NPA Publisher Operational Procedures

Day-2 operational procedures for managing NPA Publisher deployments with Terraform on Azure.

## Table of Contents

- [Publisher Upgrades](#publisher-upgrades)
- [Scaling Publishers](#scaling-publishers)
- [Rotate Netskope API Token](#rotate-netskope-api-token)
- [Replace a Failed Publisher](#replace-a-failed-publisher)
- [Manual Publisher Registration](#manual-publisher-registration)
- [Import Existing Resources](#import-existing-resources)
- [Backup and Restore](#backup-and-restore)
- [Monitoring and Alerts](#monitoring-and-alerts)

## Publisher Upgrades

### Auto-Updates (Recommended)

Netskope publishers support automatic upgrades managed through the Netskope console. This is the recommended method -- no Terraform changes required.

**Configure auto-updates in Netskope UI:**

1. Log in to your Netskope tenant
2. Go to **Settings > Security Cloud Platform > Publishers**
3. Select your publisher group
4. Enable **Auto-Update** and configure the maintenance window
5. Choose update schedule (weekly, monthly)

**Benefits:**
- No manual intervention required
- Minimal downtime during updates
- Automatic rollback on failure
- No infrastructure replacement needed

**Documentation:** [Configure Publisher Auto-Updates](https://docs.netskope.com/en/configure-publisher-auto-updates)

### Image Replacement

If you need to replace the underlying VM with a newer Marketplace image:

**Step 1: Update the image version in `terraform.tfvars`:**
```hcl
img_version = "new-version"
```

**Step 2: Replace publisher, token, and VM:**

A new VM requires a new registration token (tokens are single-use). Replace one at a time for zero-downtime:

```bash
# Replace first publisher
terraform apply \
  -replace='netskope_publishers.npa["1"]' \
  -replace='azurerm_key_vault_secret.publisher_token["1"]' \
  -replace='azurerm_linux_virtual_machine.vm["1"]'

# Wait for it to register, then replace the next
terraform apply \
  -replace='netskope_publishers.npa["2"]' \
  -replace='azurerm_key_vault_secret.publisher_token["2"]' \
  -replace='azurerm_linux_virtual_machine.vm["2"]'
```

**Step 3: Verify in Netskope UI:**
- Check **Settings > Security Cloud Platform > Publishers**
- Verify all publishers show **Connected** status

## Scaling Publishers

### Horizontal Scaling (Add/Remove Instances)

**Scale up -- add publishers** (update `terraform.tfvars`):
```hcl
gateway_count = 4  # Was 2
```
```bash
terraform plan
# Should show new resources to add for instances "3" and "4"

terraform apply
```

New publishers are automatically:
- Distributed across availability zones
- Registered with Netskope
- Named sequentially (e.g., `my-publisher-3`, `my-publisher-4`)

**Scale down -- remove publishers** (update `terraform.tfvars`):
```hcl
gateway_count = 1  # Was 2
```
```bash
terraform plan
# Should show resources to destroy for instance "2"

terraform apply
```

Terraform removes publishers from Netskope and deletes the VMs. The `for_each` pattern ensures only the specified publishers are removed.

### Vertical Scaling (Change VM Size)

**Step 1: Update VM size in `terraform.tfvars`:**
```hcl
vm_size = "Standard_B4ms"  # Was Standard_B2ms
```

**Step 2: Replace instances (VM size change requires replacement):**
```bash
terraform apply \
  -replace='netskope_publishers.npa["1"]' \
  -replace='azurerm_key_vault_secret.publisher_token["1"]' \
  -replace='azurerm_linux_virtual_machine.vm["1"]'
```

**Supported VM sizes:**

| Size | vCPU | Memory | Use Case |
|---|---|---|---|
| `Standard_B2ms` | 2 | 8 GB | Standard workloads (default) |
| `Standard_B4ms` | 4 | 16 GB | Heavy workloads |
| `Standard_D2s_v3` | 2 | 8 GB | Compute-optimised |
| `Standard_D4s_v3` | 4 | 16 GB | Compute-optimised, heavy |
| `Standard_D8s_v3` | 8 | 32 GB | Very heavy workloads |

## Rotate Netskope API Token

The Netskope API token authenticates Terraform with the Netskope API. Existing publishers are not affected by token changes.

### Step 1: Generate New Token

1. Log in to Netskope tenant
2. Go to **Settings > Tools > REST API v2**
3. Click **New Token**
4. Enable scope: **Infrastructure Management**
5. Copy the new token

### Step 2: Update `.env`

```bash
export TF_VAR_netskope_api_key="new-api-key-here"
```

Then re-source: `source .env`

### Step 3: Verify

```bash
terraform plan
# Should show "No changes" if everything is correct
```

### Step 4: Revoke Old Token

1. Go to **Settings > Tools > REST API v2** in Netskope UI
2. Find the old token
3. Click **Revoke**

## Replace a Failed Publisher

### Single Instance Replacement

Since registration tokens are single-use, replacing an instance requires replacing the Netskope publisher record, token, and VM together:

```bash
terraform apply \
  -replace='netskope_publishers.npa["1"]' \
  -replace='azurerm_key_vault_secret.publisher_token["1"]' \
  -replace='azurerm_linux_virtual_machine.vm["1"]'
```

This will:
1. Delete the old VM
2. Create a new Netskope publisher record and generate a new token
3. Store the new token in Key Vault
4. Launch a new VM
5. Bootstrap script registers the new publisher via Key Vault + managed identity

### Check Instance Health

```bash
# List VMs and their status
az vm list \
  --resource-group PRD-NPA-rg \
  --query '[].{name:name, status:powerState, zone:zones[0]}' \
  --output table --show-details

# Check boot diagnostics for a specific VM
az vm boot-diagnostics get-boot-log \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-1-vm
```

## Manual Publisher Registration

If automatic registration via cloud-init fails, you can register manually.

### Option A: Re-run via Terraform

Replace the VM to trigger a fresh bootstrap:

```bash
terraform apply \
  -replace='netskope_publishers.npa["1"]' \
  -replace='azurerm_key_vault_secret.publisher_token["1"]' \
  -replace='azurerm_linux_virtual_machine.vm["1"]'
```

### Option B: Manual Registration via Azure Bastion

#### Step 1: Get the Registration Token

```bash
# From Key Vault
az keyvault secret show \
  --vault-name <vault-name> \
  --name npa-publisher-token-1 \
  --query value -o tsv
```

#### Step 2: Connect to the Instance via Bastion

1. Go to the VM in Azure Portal
2. Click **Connect > Bastion**
3. Authenticate with your SSH key

#### Step 3: Register

```bash
# On the instance (via Bastion session):
sudo /home/ubuntu/npa_publisher_wizard -token "YOUR_REGISTRATION_TOKEN"
```

#### Step 4: Verify

```bash
# On the instance
systemctl status npa_publisher_wizard || systemctl status npa_publisher

# From the Netskope UI
# Settings > Security Cloud Platform > Publishers > verify "Connected"
```

## Import Existing Resources

If you have existing Azure resources that you want Terraform to manage:

### Import Commands

```bash
# Import a VM
terraform import 'azurerm_linux_virtual_machine.vm["1"]' /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>

# Import a VNet
terraform import 'azurerm_virtual_network.vnet' /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet-name>

# Import a Key Vault
terraform import 'azurerm_key_vault.kv' /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault-name>
```

### Post-Import Steps

1. Run `terraform plan` to see differences
2. Update `.tf` files to match actual resource configuration
3. Run `terraform plan` again to confirm "No changes"

## Backup and Restore

### Configuration Backup

Your Terraform configuration files (`.tf`) should be in Git:

```bash
git add *.tf scripts/ terraform.tfvars.example
git commit -m "Configuration backup"
git push
```

> **Never commit**: `.env` (contains secrets), `*.tfstate` files, or `.terraform/` directory.

### State Backup

**With remote state (Azure Storage):**

```bash
# Pull state to local file
terraform state pull > state-backup-$(date +%Y%m%d).json
```

### Infrastructure Backup

```bash
# Export current outputs
terraform output -json > outputs-backup-$(date +%Y%m%d).json

# Export VM details
az vm list \
  --resource-group PRD-NPA-rg \
  --output json > vms-backup-$(date +%Y%m%d).json
```

## Monitoring and Alerts

### Netskope UI Monitoring

Check publisher health in the Netskope console:
1. **Settings > Security Cloud Platform > Publishers**
2. Verify status: **Connected** (green)
3. Check last seen timestamp

### Azure Monitor

```bash
# Check VM availability
az monitor metrics list \
  --resource /subscriptions/<sub-id>/resourceGroups/PRD-NPA-rg/providers/Microsoft.Compute/virtualMachines/PRD-NPA-1-vm \
  --metric "Percentage CPU" \
  --interval PT1H
```

### Drift Detection with Terraform

Run `terraform plan` periodically to detect configuration drift:

```bash
terraform plan
```

- **"No changes"** -- Infrastructure matches configuration
- **Changes detected** -- Something was modified outside of Terraform

For CI/CD pipelines:
```bash
terraform plan -detailed-exitcode
# Exit code 0: No changes
# Exit code 1: Error
# Exit code 2: Changes detected
```

### Key Metrics to Monitor

| Metric | Source | Threshold | Action |
|---|---|---|---|
| VM Power State | Azure | Not running | Investigate / replace |
| CPU Utilisation | Azure Monitor | > 80% sustained | Scale up VM size |
| Publisher Status | Netskope UI | Not Connected | Troubleshoot |
| `terraform plan` | Terraform | Changes detected | Investigate drift |

## Additional Resources

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) -- Issue diagnosis and resolution
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) -- State operations and recovery
- [ARCHITECTURE.md](ARCHITECTURE.md) -- Architecture reference
- [Netskope Publisher Admin Guide](https://docs.netskope.com/en/netskope-help/admin/private-access/publishers)
