resource "azurerm_network_interface" "nic" {
  for_each                      = local.instances
  name                          = format("%s-%s-%s-nic", var.env_prefix, var.vm_prefix, each.key)
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = var.location
  enable_ip_forwarding          = false
  enable_accelerated_networking = false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.snet.id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}
