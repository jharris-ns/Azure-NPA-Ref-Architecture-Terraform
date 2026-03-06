provider "azurerm" {
  # The "feature" block is required for AzureRM provider 2.x. 
  # If you are using version 1.x, the "features" block is not allowed.
  features {}
}

provider "netskope" {
  baseurl  = var.netskope_server_url
  apitoken = var.netskope_api_key
}