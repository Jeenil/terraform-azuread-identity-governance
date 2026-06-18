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
# Filters by Unified group type AND resourceProvisioningOptions containing 'Team' to
# uniquely target Teams-backed groups even when other groups share the same display name.
data "msgraph_resource" "teams_groups" {
  for_each = toset(flatten([
    for catalog in var.entitlement_catalogs : [
      for package in catalog.access_packages : package.teams_resources
    ]
  ]))

  url = "/groups"
  query_parameters = {
    "$filter" = ["displayName eq '${each.value}' and groupTypes/any(c:c eq 'Unified') and resourceProvisioningOptions/any(x:x eq 'Team')"]
    "$select" = ["id,displayName,membershipRule,membershipRuleProcessingState"]
  }
  response_export_values = {
    id                               = "value[0].id"
    membership_rule                  = "value[0].membershipRule"
    membership_rule_processing_state = "value[0].membershipRuleProcessingState"
  }
}
