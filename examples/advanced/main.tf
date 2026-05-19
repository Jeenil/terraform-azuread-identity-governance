# Advanced example: member + owner split with auto-assignment and SharePoint resources.
#
# Two packages share the same resource list but grant different roles:
#   - engineering-members  → Member on all resources, auto-assigned to ICs and managers
#   - engineering-owners   → Owner on all resources, auto-assigned to directors and above
#
# The auto_assignment_policy structured fields build the OData filter automatically.
# Use the raw `filter` field instead if you need a custom expression.

module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "new-hires"
      description  = "New hire onboarding access"

      access_packages = [
        {
          display_name         = "engineering-members"
          description          = "Engineering IC and manager access"
          access_type          = "Member"
          group_resources      = ["Engineering All Staff"]
          teams_resources      = ["Engineering General"]
          sharepoint_resources = ["EngineeringDocs", "EngineeringHandbook"]
          sharepoint_base_url  = "https://contoso.sharepoint.com/sites"

          auto_assignment_policy = {
            dept_code              = "505100"
            exclude_title_prefixes = ["Director", "Vice President", "Chief"]
          }
        },
        {
          display_name         = "engineering-owners"
          description          = "Engineering director and above access"
          access_type          = "Owner"
          group_resources      = ["Engineering All Staff"]
          teams_resources      = ["Engineering General"]
          sharepoint_resources = ["EngineeringDocs", "EngineeringHandbook"]
          sharepoint_base_url  = "https://contoso.sharepoint.com/sites"

          auto_assignment_policy = {
            dept_code              = "505100"
            include_title_prefixes = ["Director", "Vice President", "Chief"]
          }
        }
      ]
    }
  ]
}
