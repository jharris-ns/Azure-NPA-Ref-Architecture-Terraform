resource "azurerm_linux_virtual_machine" "vm" {
  for_each                        = local.instances
  name                            = format("%s-%s-%s-vm", var.env_prefix, var.vm_prefix, each.key)
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg.name
  admin_username                  = var.admin_username
  disable_password_authentication = true
  size                            = var.vm_size
  zone                            = each.value.zone

  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.admin_ssh_key)
  }

  custom_data = base64encode(templatefile("${path.root}/scripts/bootstrap.tpl", {
    vault_name  = azurerm_key_vault.kv.name
    secret_name = azurerm_key_vault_secret.publisher_token[each.key].name
  }))

  network_interface_ids = [
    azurerm_network_interface.nic[each.key].id
  ]

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.stg.primary_blob_endpoint
  }

  source_image_reference {
    publisher = "netskope"
    offer     = "netskope-npa-publisher"
    sku       = var.img_sku
    version   = var.img_version
  }

  plan {
    name      = "npa_publisher"
    product   = "netskope-npa-publisher"
    publisher = "netskope"
  }

  os_disk {
    name                 = format("%s-%s-%s-disk", var.env_prefix, var.vm_prefix, each.key)
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 32
  }

  lifecycle {
    ignore_changes = [custom_data]
  }
}
