# Cross-department example: one access package shared across multiple departments.
#
# Use this when resources are genuinely shared between departments rather than
# owned by one. Both dept_code and dept_name can each take a single value —
# use raw filter when you need to OR across multiple dept codes or names.
#
# Rule: only shared resources belong here. Department-internal resources
# stay in the department's own package.

module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "shared-resources"
      description  = "Resources shared across departments"

      access_packages = [
        {
          display_name         = "brand-comms-shared"
          description          = "Shared Brand and Communications resources"
          access_type          = "Member"
          group_resources      = ["Brand Comms Shared"]
          sharepoint_resources = ["BrandCommsSharedAssets"]
          sharepoint_base_url  = "https://contoso.sharepoint.com/sites"

          # Multiple dept codes OR'd together — use raw filter since dept_code
          # only supports a single value
          auto_assignment_policy = {
            filter = "(user.extensionAttribute1 -eq \"441000\") or (user.extensionAttribute1 -eq \"442000\")"
          }
        }
      ]
    }
  ]
}
