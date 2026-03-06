# CLAUDE.md

Project-level instructions for Claude Code sessions.

## Project Context

This is a Terraform reference architecture for deploying Netskope Private Access (NPA) Publishers on Azure. It creates multi-AZ publisher instances with Key Vault token management, NAT Gateway for outbound connectivity, and managed identity integration.

### Directory Layout

- `terraform/` — All Terraform code (single flat root configuration)
- `docs/` — Project documentation
- `images/` — Screenshots and diagrams

### Key File Map

All Terraform files live in the `terraform/` directory.

| File | Purpose |
|---|---|
| `terraform/local.tf` | Core `instances` map driving all `for_each` usage and AZ distribution |
| `terraform/vm.tf` | Linux VMs with marketplace image, managed identity, and cloud-init bootstrap |
| `terraform/keyvault.tf` | Key Vault, deployer access policy, per-VM access policies, publisher token secrets |
| `terraform/npa.tf` | Netskope publisher resources (creates publishers via Netskope API) |
| `terraform/network.tf` | VNet, subnet, NAT Gateway with public IP |
| `terraform/nics.tf` | Network interfaces (one per publisher, no public IP) |
| `terraform/nsg.tf` | Shared NSG with no inbound rules, per-NIC associations |
| `terraform/scripts/bootstrap.tpl` | Cloud-init script — installs curl, fetches token from Key Vault via IMDS, runs publisher wizard |
| `terraform/storage.tf` | Boot diagnostics storage account |
| `terraform/rg.tf` | Resource group |
| `terraform/providers.tf` | AzureRM and Netskope provider configuration |
| `terraform/version.tf` | Provider version constraints |
| `terraform/variables.tf` | All input variables |
| `terraform/output.tf` | Output maps (IPs, names, zones) |

### Architecture Decisions

- **curl is installed in bootstrap.tpl** because the Netskope NPA publisher image does not include it
- **`for_each` with modulo** distributes VMs across availability zones — do not replace with `count`
- **Key Vault stores tokens** instead of embedding in `custom_data` to avoid log exposure
- **No inbound NSG rules** — publishers only initiate outbound connections
- **Azure Bastion** is documented but not Terraform-managed — deployed on demand

## Coding Standards

### Naming Conventions

- Resource names use the pattern `{env_prefix}-{vm_prefix}-{instance}-{type}` (e.g. `PRD-NPA-1-vm`)
- Terraform resource names use `snake_case`
- One resource type per `.tf` file (not everything in `main.tf`)

### Variable Handling

- **Sensitive values** (API keys, subscription ID) go in `.env` as `TF_VAR_` exports
- **Non-sensitive values** (location, sizing, naming) go in `terraform.tfvars`
- Only `netskope_api_key` is marked `sensitive = true` in Terraform
- `ARM_SUBSCRIPTION_ID` is consumed directly by the AzureRM provider (not a TF variable)

### File Organisation

- All Terraform code lives in the `terraform/` directory
- Documentation in `docs/`
- Bootstrap scripts in `terraform/scripts/`
- Images in `images/`

## Guardrails

### Never Commit

- `.env` (contains API keys and subscription ID)
- `*.tfvars` (may contain environment-specific config)
- `*.tfstate` / `*.tfstate.backup`
- `.terraform/` directory
- SSH private keys

### Do Not Modify Without Understanding

- `local.tf` — the `instances` map drives all `for_each` resources
- `scripts/bootstrap.tpl` — changes require VM replacement to take effect
- `version.tf` — provider version pins exist for compatibility

### Always Before Committing

- Run `terraform fmt`
- Run `terraform validate`
- Run `pre-commit run --all-files`

### Commit Messages

- Do not include `Co-Authored-By` lines

## Workflow Awareness

### CI Checks

- **`lint.yml`** — runs `terraform fmt -check`, `terraform validate`, `tflint` on push and PR
- **`security.yml`** — runs `gitleaks` and `checkov` on push, PR, and weekly schedule
- Checks are advisory (not blocking) — will be enforced later

### Pre-commit Hooks

- Defined in `.pre-commit-config.yaml`
- Install with `pip install pre-commit && pre-commit install`
- Runs: terraform fmt, validate, tflint, checkov, gitleaks, file checks

### Branch Protection

- PRs required to merge to `main` (no direct push)
- CI status checks shown on PRs (advisory)

## Common Pitfalls

- **Azure only supports RSA SSH keys** — ed25519 will fail at `terraform apply`
- **Netskope `baseurl`** should be `https://tenant.goskope.com` — do NOT include `/api/v2` (the provider appends it)
- **NPA publisher image lacks `curl`** — the bootstrap script installs it via `apt-get`
- **`availability_zones`** must match the target region — not all regions have 3 zones
- **Marketplace image terms** must be accepted before first deploy: `az vm image terms accept --publisher netskope --offer netskope-npa-publisher --plan npa_publisher`
- **`custom_data` has `ignore_changes`** — bootstrap script changes require VM replacement (`terraform apply -replace`)
