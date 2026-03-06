# Troubleshooting Guide

Common issues and solutions for NPA Publisher Terraform deployments on Azure.

## Table of Contents

- [Terraform Deployment Issues](#terraform-deployment-issues)
- [Netskope Provider Issues](#netskope-provider-issues)
- [VM Issues](#vm-issues)
- [Network Connectivity Issues](#network-connectivity-issues)
- [Key Vault Issues](#key-vault-issues)
- [State Issues](#state-issues)
- [Diagnostic Commands](#diagnostic-commands)

## Terraform Deployment Issues

### Issue: terraform init Fails

**Symptom:** `Error: Failed to query available provider packages`

**Causes and solutions:**

1. **No internet access:**
   ```bash
   curl -I https://registry.terraform.io
   ```

2. **Provider not found:**
   ```bash
   # Verify provider source in version.tf
   # Netskope provider source should be: netskopeoss/netskope
   ```

3. **Lock file conflict:**
   ```bash
   terraform init -upgrade
   ```

### Issue: terraform plan Shows Errors

**Symptom:** `Error: No valid credential sources found`

**Solution:** Authenticate to Azure:
```bash
az login
az account set --subscription "<subscription-id>"

# Verify
az account show
```

**Symptom:** `Error: Invalid value for variable`

**Solution:** Check your `.env` or `terraform.tfvars` values against the variable definitions in `variables.tf`.

### Issue: terraform apply Fails Partway Through

**Symptom:** Some resources created, then error

**Solution:** Fix the error and re-run `terraform apply`. Terraform is idempotent -- it will skip already-created resources and continue from where it stopped.

Common apply errors:

| Error | Cause | Solution |
|---|---|---|
| `AuthorizationFailed` | Missing Azure permissions | Check role assignments |
| `SkuNotAvailable` | VM size not available in region/zone | Try a different VM size or zone |
| `MarketplacePurchaseEligibilityFailed` | Marketplace image not accepted | Run `az vm image terms accept` |
| `QuotaExceeded` | vCPU or resource quota reached | Request quota increase |
| `PublicIPCountLimitReached` | Too many public IPs | Request quota increase or clean up |

### Issue: Marketplace Image Not Accepted

**Symptom:** `MarketplacePurchaseEligibilityFailed`

**Solution:**
```bash
az vm image terms accept \
  --publisher netskope \
  --offer netskope-npa-publisher \
  --plan npa_publisher
```

### Issue: terraform destroy Fails

**Symptom:** Resources cannot be deleted

**Common causes:**

1. **Resource lock**: Check for Azure resource locks:
   ```bash
   az lock list --resource-group PRD-NPA-rg
   ```

2. **Key Vault soft delete**: Key Vault may be in soft-deleted state:
   ```bash
   az keyvault list-deleted --query '[].name'
   az keyvault purge --name <vault-name>
   ```

3. **Netskope API error**: Publisher may already be deleted:
   ```bash
   terraform state rm 'netskope_publishers.npa["1"]'
   terraform destroy  # Retry
   ```

## Netskope Provider Issues

### Issue: Authentication Failed

**Symptom:** `Error: Authentication failed` or `401 Unauthorized`

**Solutions:**

1. **Verify API key:**
   ```bash
   echo $TF_VAR_netskope_api_key | head -c 10
   # Should show first 10 characters
   ```

2. **Check server URL format:**
   ```bash
   # Correct format (base tenant URL only -- the provider appends /api/v2 internally):
   export TF_VAR_netskope_server_url="https://mytenant.goskope.com"

   # Wrong formats:
   # https://mytenant.goskope.com/api/v2  (do NOT include /api/v2 -- the provider adds it)
   # https://mytenant.goskope.com/        (trailing slash may cause issues)
   ```

3. **Check token scopes** in Netskope UI:
   - Settings > Tools > REST API v2
   - Verify token has **Infrastructure Management** scope

### Issue: Publisher Creation Failed

**Symptom:** `Error: Failed to create publisher`

**Solutions:**

1. **Duplicate name:** Publisher names must be unique within a tenant

2. **API rate limiting:** Wait and retry:
   ```bash
   terraform apply
   ```

## VM Issues

### Issue: VM Not Starting

**Symptom:** VM power state is not `running`

**Diagnose:**
```bash
az vm list \
  --resource-group PRD-NPA-rg \
  --query '[].{name:name, status:powerState}' \
  --output table --show-details
```

**Common causes:**
- **SkuNotAvailable**: VM size not available in the requested zone
- **AllocationFailed**: Azure cannot allocate the VM in the requested zone
- **QuotaExceeded**: vCPU quota reached

### Issue: Publisher Not Registering

**Symptom:** Publisher shows as "Not Connected" in Netskope UI

**Diagnose cloud-init status** using `az vm run-command` (no Bastion required):
```bash
az vm run-command invoke \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-1-vm \
  --command-id RunShellScript \
  --scripts "cloud-init status; echo '---'; tail -30 /var/log/cloud-init-output.log"
```

**Diagnose via Azure Bastion:**

1. Connect to the VM via Azure Portal > VM > Connect > Bastion
2. Check the bootstrap log:
   ```bash
   sudo cat /var/log/cloud-init-output.log | tail -50
   ```

**Common causes:**

1. **Key Vault access denied**: VM managed identity may not have access:
   ```bash
   az keyvault show --name <vault-name> --query 'properties.accessPolicies'
   ```

2. **NAT Gateway not ready**: Outbound connectivity not available during bootstrap:
   ```bash
   # On the VM
   curl -I https://www.google.com
   ```

3. **Token already consumed**: Registration tokens are single-use. Replace the publisher:
   ```bash
   terraform apply \
     -replace='netskope_publishers.npa["1"]' \
     -replace='azurerm_key_vault_secret.publisher_token["1"]' \
     -replace='azurerm_linux_virtual_machine.vm["1"]'
   ```

### Issue: Boot Diagnostics

**View boot log:**
```bash
az vm boot-diagnostics get-boot-log \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-1-vm
```

**View serial console (Azure Portal):**
1. Go to VM > Help > Serial console
2. Requires boot diagnostics storage account (already configured)

## Network Connectivity Issues

### Issue: Publisher Not Connecting to Netskope NewEdge

**Diagnose from the VM (via Bastion):**
```bash
# Test outbound connectivity
curl -I https://www.google.com

# Test connectivity to Netskope
curl -I https://mytenant.goskope.com

# Test DNS
nslookup mytenant.goskope.com
```

**Check NAT Gateway:**
```bash
az network nat gateway show \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-nat-gw \
  --query 'provisioningState'
```

**Check subnet association:**
```bash
az network vnet subnet show \
  --resource-group PRD-NPA-rg \
  --vnet-name PRD-NPA-vnet \
  --name PRD-NPA-snet \
  --query 'natGateway.id'
```

### Issue: DNS Resolution Failing

**Diagnose from the VM:**
```bash
cat /etc/resolv.conf
nslookup mytenant.goskope.com
```

Azure VNets use Azure-provided DNS by default (168.63.129.16). If custom DNS is configured on the VNet, ensure it can resolve external domains.

## Key Vault Issues

### Issue: VM Cannot Access Key Vault

**Symptom:** Bootstrap script fails to retrieve token

**Diagnose:**
```bash
# Check VM has managed identity
az vm show \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-1-vm \
  --query 'identity.principalId'

# Check Key Vault access policies
az keyvault show \
  --name <vault-name> \
  --query 'properties.accessPolicies[].{objectId:objectId, permissions:permissions.secrets}'
```

**Common causes:**
- Key Vault access policy not yet applied (timing issue during first deploy)
- VM managed identity not yet propagated in Azure AD
- Key Vault firewall blocking access (not configured by default)

### Issue: Key Vault Soft Delete Conflict

**Symptom:** `ConflictError: A vault with the same name already exists in deleted state`

**Solution:**
```bash
# List deleted vaults
az keyvault list-deleted --query '[].name'

# Purge the deleted vault
az keyvault purge --name <vault-name>

# Retry
terraform apply
```

## State Issues

### Issue: State Lock Stuck

**Symptom:** `Error: Error acquiring the state lock`

**Solution:** Verify no other Terraform process is running, then:
```bash
terraform force-unlock LOCK_ID
```

### Issue: State Out of Sync

**Symptom:** `terraform plan` shows changes for resources that haven't actually changed

**Solution:**
```bash
terraform apply -refresh-only
```

### Issue: Lost State

**Symptom:** State file missing but infrastructure exists

**Solution:** Rebuild state by importing each resource. See [Import Existing Resources](OPERATIONS.md#import-existing-resources).

## Diagnostic Commands

### Terraform Diagnostics

```bash
# Check Terraform version and providers
terraform version

# List managed resources
terraform state list

# Show specific resource details
terraform state show 'azurerm_linux_virtual_machine.vm["1"]'

# Validate configuration
terraform validate

# Enable debug logging
TF_LOG=DEBUG terraform plan 2>terraform-debug.log
```

### Azure CLI Diagnostics

```bash
# Current identity
az account show

# List VMs in resource group
az vm list \
  --resource-group PRD-NPA-rg \
  --output table --show-details

# Check NSG rules
az network nsg rule list \
  --resource-group PRD-NPA-rg \
  --nsg-name PRD-NPA-nsg \
  --output table

# Check NAT Gateway
az network nat gateway show \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-nat-gw

# Check Key Vault secrets
az keyvault secret list \
  --vault-name <vault-name> \
  --query '[].name'
```

### Netskope API Diagnostics

```bash
# Test API connectivity
curl -v -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
  "$TF_VAR_netskope_server_url/infrastructure/publishers"

# List all publishers
curl -s -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
  "$TF_VAR_netskope_server_url/infrastructure/publishers" \
  | jq '.data.publishers[] | {publisher_name, publisher_id, status}'
```

## Getting Help

If you're still experiencing issues:

1. **Collect diagnostics** using the commands above
2. **Check Azure Service Health** for regional outages
3. **Check Netskope System Status** for service issues
4. **Review Terraform debug logs** (`TF_LOG=DEBUG terraform plan`)
5. **File an issue** on the GitHub repository with:
   - Terraform version (`terraform version`)
   - Error messages (full output)
   - Relevant diagnostic command outputs

## Additional Resources

- [OPERATIONS.md](OPERATIONS.md) -- Operational procedures
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) -- State management and recovery
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) -- Deployment instructions
- [Netskope REST API v2](https://docs.netskope.com/en/rest-api-v2-overview-312207.html)
- [Terraform Debugging](https://developer.hashicorp.com/terraform/internals/debugging)
