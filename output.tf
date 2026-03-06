output "private_ip_addresses" {
  description = "Map of publisher instance private IP addresses"
  value = {
    for k, nic in azurerm_network_interface.nic :
    k => nic.private_ip_address
  }
}

output "publisher_names" {
  description = "Map of publisher names registered in Netskope"
  value = {
    for k, pub in netskope_publishers.npa :
    k => pub.name
  }
}

output "publisher_zones" {
  description = "Map of publisher instance availability zones"
  value = {
    for k, vm in azurerm_linux_virtual_machine.vm :
    k => vm.zone
  }
}
