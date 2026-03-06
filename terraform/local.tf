locals {
  commonTags = {
    environment = var.env_prefix
  }

  instances = {
    for i in range(var.gateway_count) :
    tostring(i + 1) => {
      index = i
      name  = i == 0 ? var.publisher_name : "${var.publisher_name}-${i + 1}"
      zone  = length(var.availability_zones) > 0 ? var.availability_zones[i % length(var.availability_zones)] : null
    }
  }
}
