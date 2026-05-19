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
