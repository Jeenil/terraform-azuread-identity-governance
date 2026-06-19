# Auto-assignment lifecycle example.
#
# Auto-assignment policies grant access automatically to every user matching an
# OData filter no request, no approval. They are managed as a native
# msgraph_resource, so the policy is true desired state: changing the filter or
# the removal settings updates the live policy in place (PUT), and the change is
# visible at plan time. There is no duplicate-policy risk on re-apply.
#
# This example shows the full set of auto_assignment_policy controls plus
# hidden = true, which is the recommended pairing: an auto-assigned package is
# never requested, so hide it from the My Access request portal.
#
# membership rule reference:
#   https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-overview

module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "field-operations"
      description  = "Day-one access for the Field Operations department"

      access_packages = [
        {
          display_name    = "field-ops-members"
          description     = "Standard field operations access"
          access_type     = "Member"
          group_resources = ["Field Operations All Staff"]

          # Auto-assigned packages are not requestable hide from My Access.
          hidden = true

          auto_assignment_policy = {
            # Structured fields: department members, excluding leadership titles
            # (so owner-tier users only land in the owners package below).
            dept_name              = "Field Operations"
            exclude_title_prefixes = ["Director", "VP", "Chief"]

            # Lifecycle: when a user no longer matches the filter, revoke access
            # after a 14-day grace period instead of the 7-day default. Editing
            # either field updates the live policy in place on the next apply.
            remove_when_target_leaves   = true
            grace_period_before_removal = "P14D"
          }
        },
        {
          display_name    = "field-ops-owners"
          description     = "Field operations leadership access"
          access_type     = "Owner"
          group_resources = ["Field Operations All Staff"]

          hidden = true

          auto_assignment_policy = {
            # Owner package pattern: same department, but only leadership titles.
            dept_name              = "Field Operations"
            include_title_prefixes = ["Director", "VP", "Chief"]

            # Keep owner access for 30 days after a title/department change.
            remove_when_target_leaves   = true
            grace_period_before_removal = "P30D"
          }
        }
      ]
    }
  ]
}
