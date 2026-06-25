# Application (app role) resources example.
#
# Attach an enterprise application's *app role* to an access package using the
# `resources` escape hatch with resource_origin_system = "AadApplication":
#   - resource_origin_id is the service principal (enterprise app) OBJECT id, and
#   - access_type is an app role id (a UUID) exposed by that application.
#
# Display-name resolution (group_resources / teams_resources / sharepoint_resources)
# does not cover apps, so AadApplication resources are always passed via `resources`.
#
# Requires the azuread provider with native AadApplication support in
# azuread_access_package_resource_package_association
# (hashicorp/terraform-provider-azuread#1880). Until that ships, point the provider at
# the patched build via a dev_override — see the "TEMP wiring" notes in the repo.

module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "line-of-business-apps"
      description  = "Access to internal applications"

      access_packages = [
        {
          display_name = "salesforce-viewer"
          description  = "Read-only Salesforce app role"

          resources = [
            {
              resource_origin_system = "AadApplication"
              resource_origin_id     = "00000000-0000-0000-0000-000000000000" # enterprise app (service principal) object id
              access_type            = "11111111-1111-1111-1111-111111111111" # app role id (UUID) exposed by that app
            }
          ]
        }
      ]
    }
  ]
}
