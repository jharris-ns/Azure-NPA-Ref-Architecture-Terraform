# Azure Bastion Access Guide

How to deploy Azure Bastion and connect to NPA Publisher instances without exposing SSH ports.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Deploy Azure Bastion](#deploy-azure-bastion)
- [Connect to a Publisher Instance](#connect-to-a-publisher-instance)
- [SSH Key Management](#ssh-key-management)
- [Clean Up](#clean-up)
- [Cost](#cost)

## Overview

Azure Bastion provides browser-based and CLI-based SSH access to VMs over TLS (port 443). The NPA Publisher VMs are deployed in a private subnet with no inbound NSG rules -- Bastion is the recommended way to access them.

**Benefits over traditional SSH:**
- No public IP required on VMs
- No inbound SSH port (22) exposure
- No bastion VM to manage -- fully managed PaaS service
- Access via Azure Portal (browser) or Azure CLI
- Azure AD/Entra ID authentication supported
- All sessions logged in Azure Monitor

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Contributor role on the resource group or subscription
- The NPA Publisher deployment completed (`terraform apply`)
- SSH key pair (the same key used during deployment)

## Deploy Azure Bastion

Azure Bastion requires a dedicated subnet named exactly `AzureBastionSubnet` with a minimum `/26` prefix.

### Step 1: Create the AzureBastionSubnet

```bash
# Get the VNet and resource group from your deployment
RG="PRD-NPA-rg"
VNET="PRD-NPA-vnet"

# Create the Bastion subnet (must be named exactly AzureBastionSubnet)
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name $VNET \
  --name AzureBastionSubnet \
  --address-prefixes 10.0.2.0/26
```

> **Note**: The address prefix must not overlap with the publisher subnet (10.0.1.0/24). The example uses 10.0.2.0/26.

### Step 2: Create a Public IP for Bastion

```bash
az network public-ip create \
  --resource-group $RG \
  --name PRD-NPA-bastion-pip \
  --sku Standard \
  --allocation-method Static
```

### Step 3: Create the Bastion Host

```bash
# Basic SKU (browser-based access only)
az network bastion create \
  --resource-group $RG \
  --name PRD-NPA-bastion \
  --public-ip-address PRD-NPA-bastion-pip \
  --vnet-name $VNET \
  --sku Basic

# Or Standard SKU (adds CLI access, file transfer, shareable links)
az network bastion create \
  --resource-group $RG \
  --name PRD-NPA-bastion \
  --public-ip-address PRD-NPA-bastion-pip \
  --vnet-name $VNET \
  --sku Standard \
  --enable-tunneling true
```

Provisioning takes 5-10 minutes.

### Verify Bastion Deployment

```bash
az network bastion show \
  --resource-group $RG \
  --name PRD-NPA-bastion \
  --query '{name:name, sku:sku.name, state:provisioningState}' \
  --output table
```

## Connect to a Publisher Instance

### Option A: Azure Portal (Basic or Standard SKU)

1. Go to the **Azure Portal**
2. Navigate to your VM (e.g., `PRD-NPA-1-vm`)
3. Click **Connect > Bastion**
4. Select **Authentication Type**: SSH Private Key from Local File
5. **Username**: your admin username (e.g., `jharris`)
6. **SSH Private Key from Local File**: upload your private key file
7. Click **Connect**

A browser-based terminal session opens.

### Option B: Azure CLI (Standard SKU only)

The CLI method requires the Standard SKU with tunneling enabled.

```bash
# Get the VM resource ID
VM_ID=$(az vm show \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-1-vm \
  --query id -o tsv)

# Connect using native SSH via Bastion tunnel
az network bastion ssh \
  --name PRD-NPA-bastion \
  --resource-group PRD-NPA-rg \
  --target-resource-id $VM_ID \
  --auth-type ssh-key \
  --username jharris \
  --ssh-key ~/.ssh/id_rsa
```

> **Note**: The `--ssh-key` flag takes the **private** key path (not the public key used during deployment).

### Option C: SSH Tunnel via Bastion (Standard SKU only)

Open a tunnel for use with standard SSH tools, SCP, or port forwarding:

```bash
# Open a tunnel on local port 2222
az network bastion tunnel \
  --name PRD-NPA-bastion \
  --resource-group PRD-NPA-rg \
  --target-resource-id $VM_ID \
  --resource-port 22 \
  --port 2222

# In another terminal, connect via the tunnel
ssh -i ~/.ssh/id_rsa -p 2222 jharris@127.0.0.1

# Or copy files via the tunnel
scp -i ~/.ssh/id_rsa -P 2222 localfile.txt jharris@127.0.0.1:/tmp/
```

## SSH Key Management

### Key Pair Used During Deployment

The Terraform deployment uses the public key specified by `admin_ssh_key` in `terraform.tfvars` (e.g., `~/.ssh/id_rsa.pub`). This public key is injected into the VM's `~/.ssh/authorized_keys` for the admin user.

> **Important**: Azure VMs only support RSA SSH keys. Ed25519 keys are not supported and will be rejected during deployment.

**To connect, you need the corresponding private key** (e.g., `~/.ssh/id_rsa`).

### Generating a New Key Pair

If you need a new key pair:

```bash
# Generate an RSA key (required for Azure VMs -- ed25519 is not supported)
ssh-keygen -t rsa -b 4096 -C "npa-publisher-access" -f ~/.ssh/npa_publisher
```

This creates:
- `~/.ssh/npa_publisher` -- private key (keep secure, never share)
- `~/.ssh/npa_publisher.pub` -- public key (set as `admin_ssh_key` in `terraform.tfvars`)

### Rotating SSH Keys

To rotate the SSH key on existing VMs without replacing them:

```bash
# Update the key on a running VM
az vm user update \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-1-vm \
  --username jharris \
  --ssh-key-value "$(cat ~/.ssh/new_key.pub)"
```

Then update `terraform.tfvars` to point to the new public key for future deployments:

```hcl
admin_ssh_key = "~/.ssh/new_key.pub"
```

> **Note**: Changing `admin_ssh_key` in Terraform will trigger VM replacement on the next `terraform apply` (since it changes the `admin_ssh_key` block). Use `az vm user update` to rotate keys without downtime.

### Revoking Access

To remove an SSH key from a VM:

```bash
az vm user delete \
  --resource-group PRD-NPA-rg \
  --name PRD-NPA-1-vm \
  --username jharris
```

### Key Security Best Practices

| Practice | Description |
|---|---|
| Use Ed25519 keys | Smaller, faster, and more secure than RSA |
| Passphrase-protect private keys | `ssh-keygen` prompts for a passphrase by default |
| Never commit private keys | `.gitignore` should exclude `*.pem`, `id_*` (without `.pub`) |
| Use ssh-agent | Avoid typing passphrases repeatedly |
| Rotate keys periodically | Use `az vm user update` for in-place rotation |
| One key per purpose | Don't reuse keys across unrelated systems |

### Using ssh-agent

```bash
# Start the agent
eval "$(ssh-agent -s)"

# Add your key (prompts for passphrase once)
ssh-add ~/.ssh/id_rsa

# Verify
ssh-add -l
```

## Clean Up

To remove Azure Bastion when no longer needed:

```bash
RG="PRD-NPA-rg"

# Delete Bastion host
az network bastion delete \
  --resource-group $RG \
  --name PRD-NPA-bastion

# Delete the public IP
az network public-ip delete \
  --resource-group $RG \
  --name PRD-NPA-bastion-pip

# Delete the Bastion subnet
az network vnet subnet delete \
  --resource-group $RG \
  --vnet-name PRD-NPA-vnet \
  --name AzureBastionSubnet
```

## Cost

| SKU | Approximate Cost | Features |
|---|---|---|
| **Basic** | ~$0.19/hr (~$140/month) | Portal-based SSH/RDP only |
| **Standard** | ~$0.35/hr (~$260/month) | CLI access, tunneling, file transfer, shareable links |

Bastion is billed per hour while deployed. To reduce cost:
- Deploy Bastion only when access is needed
- Use the Basic SKU if portal access is sufficient
- Delete Bastion after troubleshooting sessions

> **Tip**: For occasional access, deploy Bastion on demand using the CLI commands above and delete it when done. The 5-10 minute provisioning time is acceptable for non-urgent access.

## Additional Resources

- [Azure Bastion Documentation](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview)
- [Connect via SSH using Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-connect-vm-ssh-linux)
- [Azure CLI Bastion Commands](https://learn.microsoft.com/en-us/cli/azure/network/bastion)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) -- General troubleshooting
- [OPERATIONS.md](OPERATIONS.md) -- Day-2 operations
