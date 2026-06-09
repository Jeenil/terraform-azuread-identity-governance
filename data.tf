# Looks up existing catalogs when create_catalog = false.
# Allows multiple Terraform states to share one Entra catalog without conflict.
data "azuread_access_package_catalog" "existing" {
  for_each     = { for catalog in local.entitlement-catalogs : catalog.display_name => catalog if !catalog.create_catalog }
  display_name = each.key
}

# Resolves Entra ID group and Teams team display names to object IDs.
# Teams teams are backed by M365 groups so both inputs use the same azuread_group
# data source - they are kept separate in variables.tf for easier distinction for the callers.
# The data source errors at plan time if the display name matches more than one group.
data "azuread_group" "resources" {
  for_each = toset(flatten([
    for catalog in var.entitlement_catalogs : [
      for package in catalog.access_packages : concat(package.group_resources, package.teams_resources)
    ]
  ]))

  display_name = each.value
}
