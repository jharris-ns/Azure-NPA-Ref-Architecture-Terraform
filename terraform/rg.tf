resource "azurerm_resource_group" "rg" {
  name     = format("%s%s%s%s%s", var.env_prefix, "-", var.vm_prefix, "-", "rg")
  location = var.location
  tags     = local.common_tags
}