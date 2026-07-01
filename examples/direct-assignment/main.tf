# Direct (one-off) assignment example.
#
# auto_assignment_policy covers the dept-wide population by OData filter. For the
# exceptions it can't express  a contractor in another department, a one-off grant
# list the specific users in direct_assignments. Each user principal name is resolved
# to an object ID and AdminAdded to the package through its request-based policy
# (admin-initiated, so no request or approval is needed).
#
# The list is desired state for these grants:
#   - add a UPN    -> the user is AdminAdded on the next apply (idempotent: skipped
#                     if they already have an active assignment).
#   - remove a UPN -> their assignment is AdminRemoved on the next apply.
#
# The provisioner only runs when an entry is added/removed (or the resolved
# user/package/policy id changes), so a steady-state apply makes no extra Graph
# calls for already-assigned users.

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

          # The department population is granted automatically by the filter.
          auto_assignment_policy = {
            dept_name              = "Field Operations"
            exclude_title_prefixes = ["Director", "VP", "Chief"]
          }

          # One-offs the filter does not match e.g. a cross-department contractor
          # and a temporary backfill who should still get this package.
          direct_assignments = [
            "contractor.jane@contoso.com",
            "backfill.lee@contoso.com",
          ]
        }
      ]
    }
  ]
}
