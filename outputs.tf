###   Outputs
################
output "entitlement_catalogs" {
  description = "Outputs all Entitlement Catalogs created through this module"
  value       = azuread_access_package_catalog.entitlement-catalogs[*]
}

output "access_packages" {
  description = "Outputs all Access Packages created through this module"
  value       = azuread_access_package.access-packages[*]
}

output "assignment_policies" {
  description = "Outputs all Access Package Assignment Policies created through this module"
  value       = azuread_access_package_assignment_policy.assignment_policies[*]
}

output "resource_catalog_associations" {
  description = "Outputs all Resources associated with the Entitlement Catalogs"
  value       = null_resource.catalog-associations[*]
}

output "resource_access_package_associations" {
  description = "Outputs all Resources associated with the Access Packages"
  value       = azuread_access_package_resource_package_association.resource-access-package-associations[*]
}

output "auto_assignment_policies" {
  description = "Auto-assignment policies managed through this module, keyed by \"<catalog>-<package>\". Exposes the live policy id and membership rule (resolved OData filter) for downstream modules and CI assertions."
  value = {
    for key, policy in msgraph_resource.auto-assignment-policies :
    key => {
      id              = policy.output.id
      membership_rule = policy.output.membership_rule
    }
  }
}

output "catalog_ids" {
  description = "Resolved Entra catalog IDs keyed by catalog display name, whether the catalog was created by this module or looked up."
  value       = local.catalog_ids
}