# Advanced example: member + owner split with auto-assignment and SharePoint resources.
#
# Two packages share the same resource list but grant different roles:
#   - engineering-members  → Member on all resources, auto-assigned to ICs and managers
#   - engineering-owners   → Owner on all resources, auto-assigned to directors and above
#
# Catalog-level dept_code and management_title_prefixes are inherited by both packages,
# eliminating the need to repeat them. is_owner_package drives the filter direction:
#   false (default) → EXCLUDES management_title_prefixes  (everyone except leadership)
#   true            → INCLUDES management_title_prefixes  (leadership only)
#
# Set enabled = false on the owners package to drop it for cohorts with no leadership split.
# Use the raw `filter` field instead of structured fields for fully custom expressions.

module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "new-hires"
      description  = "New hire onboarding access"

      # ── Catalog-level defaults inherited by all packages ─────────────────
      dept_code                 = "505100"
      management_title_prefixes = ["Director", "Vice President", "Chief"]
      # create_owners_package = false  # uncomment to drop the owners package for cohorts with no leadership split

      access_packages = [
        {
          display_name         = "engineering-members"
          description          = "Engineering IC and manager access — everyone in the department except leadership"
          access_type          = "Member"
          group_resources      = ["Engineering All Staff"]
          teams_resources      = ["Engineering General"]
          sharepoint_resources = ["EngineeringDocs", "EngineeringHandbook"]
          sharepoint_base_url  = "https://contoso.sharepoint.com/sites"

          # is_owner_package defaults to false → management_title_prefixes are EXCLUDED
          auto_assignment_policy = {}
        },
        {
          display_name         = "engineering-owners"
          description          = "Engineering director and above — leadership only"
          access_type          = "Owner"
          group_resources      = ["Engineering All Staff"]
          teams_resources      = ["Engineering General"]
          sharepoint_resources = ["EngineeringDocs", "EngineeringHandbook"]
          sharepoint_base_url  = "https://contoso.sharepoint.com/sites"

          # create_owners_package = false at the catalog level skips this package entirely

          # is_owner_package = true → management_title_prefixes are INCLUDED
          auto_assignment_policy = {
            is_owner_package = true
          }
        }
      ]
    }
  ]
}
