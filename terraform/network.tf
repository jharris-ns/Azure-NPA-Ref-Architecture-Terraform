resource "azurerm_virtual_network" "vnet" {
  name                = format("%s-%s-vnet", var.env_prefix, var.vm_prefix)
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_address_space]
  tags                = local.common_tags
}

resource "azurerm_subnet" "snet" {
  name                 = format("%s-%s-snet", var.env_prefix, var.vm_prefix)
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.snet_address_prefix]
}

resource "azurerm_public_ip" "nat_pip" {
  name                = format("%s-%s-nat-pip", var.env_prefix, var.vm_prefix)
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_nat_gateway" "nat" {
  name                = format("%s-%s-nat-gw", var.env_prefix, var.vm_prefix)
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
  tags                = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "nat_pip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "snet_nat_assoc" {
  subnet_id      = azurerm_subnet.snet.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}
