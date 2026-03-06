variable "location" {
  type        = string
  description = "Azure region for resource deployment."
  default     = "uksouth"
}

variable "vnet_address_space" {
  type        = string
  description = "Address space for the virtual network."
  default     = "10.0.0.0/16"
}

variable "snet_address_prefix" {
  type        = string
  description = "Address prefix for the publisher subnet."
  default     = "10.0.1.0/24"
}

variable "env_prefix" {
  type        = string
  description = "Environment prefix to use to label resources in cloud deployment."
  default     = "PRD"
}

variable "vm_prefix" {
  type        = string
  description = "The vm Prefix details of the VM."
  default     = "NPA"
}

variable "vm_size" {
  type        = string
  description = "The Virtual Machine Size for the publisher VM deployment."
  default     = "Standard_B2ms"
}

variable "admin_username" {
  type        = string
  description = "The Virtual Machine default local admin username."
  default     = ""
}

variable "img_sku" {
  type        = string
  description = "Azure Marketplace default image sku."
  default     = "npa_publisher"
}

variable "img_version" {
  type        = string
  description = "Publisher version. By default the latest available version in the Azure Marketplace is selected."
  default     = "latest"
}

variable "admin_ssh_key" {
  type        = string
  description = "File path for the admin public SSH key."
  default     = ""
}

variable "publisher_name" {
  type        = string
  description = "Base name for the netskope publishers to create in netskope tenant."
}

variable "gateway_count" {
  type        = number
  description = "Number of NPA publisher instances to deploy across availability zones."
  default     = 2
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones to distribute publishers across. Set to empty list for regions without zone support."
  default     = ["1", "2", "3"]
}

variable "netskope_server_url" {
  type        = string
  description = "Netskope API v2 base URL."
}

variable "netskope_api_key" {
  type        = string
  description = "Netskope API token."
  sensitive   = true
}
