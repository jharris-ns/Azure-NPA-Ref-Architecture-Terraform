terraform {
  #All the available versions for terraform are listed here; https://releases.hashicorp.com/terraform/. 
  required_version = ">= 0.13.0"
  required_providers {
    # version 2.0 of the AzureRM Provider requires Terraform 0.12.x and later.
    # Recommended to pin to the specific version of the Azure Provider 
    # since new versions are released frequently and it's known to break code etc.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.11.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.1.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.2.3"
    }
    netskope = {
      source  = "netskopeoss/netskope"
      version = "0.2.1"
    }
  }
}
