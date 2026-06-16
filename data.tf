# Looks up existing catalogs when create_catalog = false.
# Allows multiple Terraform states to share one Entra catalog without conflict.
data "azuread_access_package_catalog" "existing" {
  for_each     = { for catalog in local.entitlement-catalogs : catalog.display_name => catalog if !catalog.create_catalog }
  display_name = each.key
}

# Resolves Entra ID security/M365 group display names to object IDs.
data "azuread_group" "groups" {
  for_each = toset(flatten([
    for catalog in var.entitlement_catalogs : [
      for package in catalog.access_packages : package.group_resources
    ]
  ]))

  display_name = each.value
}

# Resolves Teams team display names to their backing M365 group object IDs.
# Filters to mail-enabled, non-security groups to avoid ambiguity when a security
# group shares the same display name as the Teams-backed M365 group.
data "azuread_group" "teams" {
  for_each = toset(flatten([
    for catalog in var.entitlement_catalogs : [
      for package in catalog.access_packages : package.teams_resources
    ]
  ]))

  display_name     = each.value
  mail_enabled     = true
  security_enabled = false
}
