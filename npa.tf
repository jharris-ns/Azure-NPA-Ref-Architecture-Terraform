resource "netskope_publishers" "npa" {
  for_each = local.instances
  name     = each.value.name
}
