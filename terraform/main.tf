# Main entrypoint — resource definitions are split across:
#   rg.tf        - Resource group
#   network.tf   - VNet, subnet, NAT gateway
#   nsg.tf       - Network security group
#   nics.tf      - Network interfaces
#   keyvault.tf  - Key Vault and access policies
#   storage.tf   - Boot diagnostics storage
#   npa.tf       - Netskope publisher resources
#   vm.tf        - Linux virtual machines
