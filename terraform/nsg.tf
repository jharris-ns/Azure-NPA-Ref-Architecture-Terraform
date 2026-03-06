resource "azurerm_network_security_group" "nsg" {
  name                = format("%s-%s-nsg", var.env_prefix, var.vm_prefix)
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_network_interface_security_group_association" "nic_nsg_association" {
  for_each                  = local.instances
  network_interface_id      = azurerm_network_interface.nic[each.key].id
  network_security_group_id = azurerm_network_security_group.nsg.id
}
