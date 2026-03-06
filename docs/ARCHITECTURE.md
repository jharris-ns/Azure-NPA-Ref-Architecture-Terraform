# Architecture Overview

Azure reference architecture for deploying Netskope Private Access (NPA) Publishers using Terraform. This document explains each design decision through the lens of Azure best practices and the [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/).

## Table of Contents

- [Architecture Diagram](#architecture-diagram)
- [Component Overview](#component-overview)
- [Network Architecture](#network-architecture)
- [Security Architecture](#security-architecture)
- [High Availability Design](#high-availability-design)
- [Additional Resources](#additional-resources)

## Architecture Diagram

```
                                                       +----------------------------+
                                                       |  Terraform Operator        |
                                                       |  (Workstation / CI/CD)     |
                                                       +--------------+-------------+
                                                                      |
                                                                      | Terraform API Calls
                                                                      v
+---------------------------------------------------------------------------------+
|                              Azure Cloud                                         |
|                                                                                  |
|  +------------------------------------------------------------------------+     |
|  |                    Azure Services                                       |     |
|  |                                                                         |     |
|  |  +--------------+  +--------------+  +--------------+                  |     |
|  |  |  Key Vault   |  |   Managed    |  |   Storage    |                  |     |
|  |  | (Publisher   |  |  Identity    |  |  Account     |                  |     |
|  |  |  Tokens)     |  | (VM Auth)    |  | (Boot Diag)  |                  |     |
|  |  +--------------+  +--------------+  +--------------+                  |     |
|  +------------------------------------------------------------------------+     |
|                                                                                  |
|  +------------------------------------------------------------------------+     |
|  |               Resource Group (PRD-NPA-rg)                               |     |
|  |                                                                         |     |
|  |  +------------------------------------------------------------------+  |     |
|  |  |                    VNet (10.0.0.0/16)                             |  |     |
|  |  |                                                                    |  |     |
|  |  |  +------------------------------------------------------------+  |  |     |
|  |  |  |              Private Subnet (10.0.1.0/24)                   |  |  |     |
|  |  |  |              Spans all Availability Zones                   |  |  |     |
|  |  |  |                                                              |  |  |     |
|  |  |  |  +------------------+  +------------------+                 |  |  |     |
|  |  |  |  | AZ 1             |  | AZ 2             |                 |  |  |     |
|  |  |  |  |                  |  |                   |                 |  |  |     |
|  |  |  |  | +------------+  |  | +------------+    |                 |  |  |     |
|  |  |  |  | |    NPA     |  |  | |    NPA     |    |                 |  |  |     |
|  |  |  |  | | Publisher  |  |  | | Publisher  |    |                 |  |  |     |
|  |  |  |  | | Instance 1 |  |  | | Instance 2 |    |                 |  |  |     |
|  |  |  |  | +------------+  |  | +------------+    |                 |  |  |     |
|  |  |  |  +------------------+  +------------------+                 |  |  |     |
|  |  |  |                                                              |  |  |     |
|  |  |  +-------------------------------+----------------------------+  |  |     |
|  |  |                                   |                              |  |     |
|  |  +-----------------------------------+------------------------------+  |     |
|  |                                      |                                 |     |
|  |                            +---------v----------+                      |     |
|  |                            |    NAT Gateway      |                      |     |
|  |                            |  (Static Public IP) |                      |     |
|  |                            +----------+----------+                      |     |
|  +------------------------------------------------------------------------+     |
|                                          |                                       |
|                                          | HTTPS 443                             |
+----------------------------------------------------------------------------------+
                                           |
                                           v
                            +--------------+---------------+
                            |  Netskope NewEdge Network    |
                            |  (Publisher Management)      |
                            +------------------------------+
```

## Component Overview

### Virtual Network and Subnet Design

**Azure best practice**: Place workloads in private subnets and use NAT Gateway for outbound connectivity ([Azure networking best practices](https://learn.microsoft.com/en-us/azure/virtual-network/concepts-and-best-practices)).

- **VNet** (10.0.0.0/16, configurable): Isolated network environment.
- **Private Subnet** (10.0.1.0/24): Hosts all NPA Publisher VMs. No public IP addresses. In Azure, a single subnet spans all availability zones within a region -- no per-AZ subnet required.
- **NAT Gateway**: Provides outbound internet access for all VMs in the subnet via a static public IP.

### NAT Gateway

**Azure best practice**: Use NAT Gateway for predictable outbound connectivity from private subnets ([NAT Gateway documentation](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview)).

- Single NAT Gateway with a static public IP
- Associated with the publisher subnet
- Provides SNAT for all outbound connections
- Managed service with built-in redundancy

### Linux Virtual Machines (NPA Publishers)

**Azure best practice**: Use managed identities instead of credentials stored in code or configuration ([SE:05 Identity and access management](https://learn.microsoft.com/en-us/azure/well-architected/security/identity-access)).

- **VM size**: Standard_B2ms (default, configurable)
- **Image**: Netskope Private Access Publisher (Azure Marketplace)
- **Deployment**: Distributed across availability zones using `for_each` with modulo distribution
- **Networking**: Private subnet placement (no public IP)
- **Identity**: System-assigned managed identity for Key Vault access
- **Storage**: 32 GB Premium SSD OS disk
- **Boot diagnostics**: Enabled via Storage Account for serial console access

### Network Security Group

**Azure best practice**: Apply the principle of least privilege to network access ([SE:06 Networking](https://learn.microsoft.com/en-us/azure/well-architected/security/networking)).

- **Inbound**: No custom rules -- publishers only initiate outbound connections, giving them zero inbound attack surface
- **Outbound**: Azure default rules allow all outbound traffic
- **Remote access**: Azure Bastion (not deployed by this template -- add separately when needed)

### Key Vault

**Azure best practice**: Use Key Vault for secret management with managed identity access ([SE:09 Application secrets](https://learn.microsoft.com/en-us/azure/well-architected/security/application-secrets)).

- Stores Netskope publisher registration tokens (one per publisher)
- Deployer gets Set/Get/Delete/Purge permissions
- Each VM's managed identity gets Get-only access to its own token
- Soft delete enabled with 7-day retention

### Netskope Provider

The Netskope Terraform provider creates publisher records and generates registration tokens used during the cloud-init bootstrap. It does not manage any Azure infrastructure.

- `netskope_publishers`: Creates publisher records and generates registration tokens
- Authentication: API key (set via environment variable)

## Network Architecture

### Traffic Flows

#### 1. Publisher to Netskope NewEdge
```
NPA Publisher -> NSG (outbound) -> NAT Gateway ->
Internet -> Netskope NewEdge Data Centers
```
- **Port**: HTTPS (443)
- **Purpose**: Publisher registration, management plane, tunnel establishment

#### 2. Publisher to Internal Applications
```
NPA Publisher -> NSG (outbound) ->
VNet Internal / Peered VNets / On-Premises (via VPN/ExpressRoute)
```
- **Ports**: Application-specific
- **Destination**: RFC1918 private IP ranges
- **Purpose**: Proxying user traffic to internal applications via Netskope tunnels

#### 3. Publisher to Key Vault (Token Retrieval)
```
NPA Publisher -> Managed Identity (IMDS) ->
Azure Key Vault Service Endpoint
```
- **Port**: HTTPS (443)
- **Purpose**: Retrieving registration token during initial bootstrap
- **One-time operation**: Only occurs during first boot

#### 4. Terraform Operator to Azure / Netskope APIs
```
Terraform Operator -> Azure APIs (create/manage resources)
                   -> Netskope APIs (create publishers, generate tokens)
```
- **Port**: HTTPS (443)
- **Source**: Operator workstation or CI/CD pipeline

### Network Segmentation

| Plane | Traffic | Azure Mechanism |
|---|---|---|
| **Data Plane** | Publisher <-> Netskope NewEdge, internal apps | Private subnet -> NAT Gateway -> Internet / VNet peering |
| **Management Plane** | Operator <-> Publisher (shell access) | Azure Bastion (deployed separately) |
| **Control Plane** | Terraform <-> Azure APIs, Netskope APIs | External (operator workstation / CI/CD) over HTTPS |

## Security Architecture

This architecture implements defense in depth aligned to the [Azure Well-Architected Security Pillar](https://learn.microsoft.com/en-us/azure/well-architected/security/).

### Layer 1: Network Security

- Private subnet placement for all VMs
- No public IP addresses assigned to publishers
- NAT Gateway for outbound-only internet access
- NSG with no inbound rules (zero inbound attack surface)
- Azure Bastion for remote access (no SSH port exposure)

### Layer 2: Identity and Access Management

**Managed identity design** ensures least privilege:

| Identity | Type | Purpose |
|---|---|---|
| **VM Managed Identity** | System-assigned | Key Vault secret retrieval (Get only) |
| **Terraform Operator** | Azure CLI / Service Principal | Manages all resources |
| **Key Vault Access** | Access policies | Scoped per-identity permissions |

### Layer 3: Data Protection at Rest

- **Key Vault**: Tokens encrypted at rest with Azure platform keys
- **Terraform State**: Should use Azure Storage backend with encryption (see [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md))
- **VM OS Disk**: Premium SSD with Azure-managed encryption

### Layer 4: Data Protection in Transit

- All Azure API calls: TLS 1.2+
- Netskope communication: TLS 1.3
- Key Vault access: HTTPS only
- IMDS access: Local-only (169.254.169.254)

### Layer 5: Secret Management

- Registration tokens stored in Key Vault (not in custom_data or Terraform output)
- Tokens marked as `sensitive` in Terraform to suppress plan output
- Each VM can only access its own token via scoped access policy
- Tokens are single-use -- consumed during registration

## High Availability Design

### Multi-AZ Architecture

#### Availability Zone Distribution

**Active-Active Design:**
- Publishers distributed across AZs using `for_each` with modulo:
  ```hcl
  zone = var.availability_zones[i % length(var.availability_zones)]
  ```
- Each instance handles traffic independently
- No active-passive failover required
- Single subnet spans all AZs (Azure design -- no per-AZ subnets needed)

**Zone-Isolated Failure Domains:**
- AZ1 failure: Other AZs continue serving traffic
- Each publisher operates independently
- NAT Gateway provides built-in redundancy

#### Failure Scenarios and Recovery

**Scenario 1: Single Instance Failure**
- **Impact**: Reduced capacity (remaining instances continue serving)
- **Recovery**: `terraform apply -replace='azurerm_linux_virtual_machine.vm["1"]'`
- **Automatic**: Remaining instances continue without intervention

**Scenario 2: Availability Zone Failure**
- **Impact**: Instances in affected AZ unavailable
- **Recovery**: Healthy AZs continue serving all traffic automatically

**Scenario 3: Region-Wide Failure**
- **Impact**: Entire deployment unavailable
- **Recovery**: Deploy in different region using same Terraform configuration

### Capacity and Scalability

**Scaling Publishers** (update `terraform.tfvars`):
```hcl
gateway_count = 4  # Scale from 2 to 4
```
```bash
terraform apply
```

**Vertical Scaling** (update `terraform.tfvars`):
```hcl
vm_size = "Standard_B4ms"
```
Requires VM replacement.

| VM Size | vCPU | Memory | Approximate Capacity |
|---|---|---|---|
| Standard_B2ms | 2 | 8 GB | ~2,000 concurrent users |
| Standard_B4ms | 4 | 16 GB | ~4,000 concurrent users |
| Standard_D2s_v3 | 2 | 8 GB | ~2,000 concurrent users |
| Standard_D4s_v3 | 4 | 16 GB | ~4,000 concurrent users |
| Standard_D8s_v3 | 8 | 32 GB | ~8,000 concurrent users |

### RPO and RTO

**Recovery Point Objective (RPO):**
- **Data Loss**: None (stateless publishers)
- **Configuration**: Stored in Git (version controlled .tf files)
- **Netskope State**: Maintained by Netskope cloud
- **Terraform State**: Azure Storage versioning provides point-in-time recovery

**Recovery Time Objective (RTO):**
- **Single Instance**: Minutes (`terraform apply -replace`)
- **Availability Zone**: 0 seconds (automatic failover)
- **Entire Stack**: ~5-10 minutes (`terraform apply` from scratch)

## Additional Resources

- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) -- Terraform state guide
- [QUICKSTART.md](QUICKSTART.md) -- Quick deployment guide
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) -- Detailed deployment instructions
- [DEVOPS-NOTES.md](DEVOPS-NOTES.md) -- Technical deep-dive
- [OPERATIONS.md](OPERATIONS.md) -- Day-2 operational procedures
