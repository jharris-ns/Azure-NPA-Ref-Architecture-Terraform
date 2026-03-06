resource "azurerm_key_vault" "kv" {
  name                       = lower(format("%s%s%s", var.env_prefix, var.vm_prefix, random_id.storage_id.hex))
  location                   = var.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Set",
      "Get",
      "Delete",
      "Purge",
    ]
  }

  tags = local.common_tags
}

resource "azurerm_key_vault_access_policy" "vm_access" {
  for_each     = local.instances
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_virtual_machine.vm[each.key].identity[0].principal_id

  secret_permissions = [
    "Get",
  ]
}

resource "azurerm_key_vault_secret" "publisher_token" {
  for_each     = local.instances
  name         = format("npa-publisher-token-%s", each.key)
  value        = netskope_publishers.npa[each.key].token
  key_vault_id = azurerm_key_vault.kv.id
}
