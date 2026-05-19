# Raw filter example: use any valid Entra OData expression directly.
#
# Use this when the structured fields (dept_code, dept_name, exclude/include_title_prefixes)
# don't cover your attribute set. The raw filter is passed to the assignment policy unchanged.
#
# Common patterns:
#   user.extensionAttribute3 -eq "FTE"           custom HR attribute
#   user.companyName -eq "Contoso"               multi-entity tenants
#   user.usageLocation -eq "US"                  geography-based access
#   user.accountEnabled -eq true                 active users only (usually combined with other conditions)
#
# Any valid Entra dynamic membership rule expression works here.
# See: https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-overview

module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "us-employees"
      description  = "Access for US-based full-time employees"

      access_packages = [
        {
          display_name    = "us-fte-members"
          description     = "US FTE standard access"
          access_type     = "Member"
          group_resources = ["US Employees All Staff"]

          auto_assignment_policy = {
            filter = "(user.extensionAttribute3 -eq \"FTE\") and (user.usageLocation -eq \"US\")"
          }
        },
        {
          display_name    = "us-fte-managers"
          description     = "US FTE manager access"
          access_type     = "Owner"
          group_resources = ["US Employees All Staff"]

          auto_assignment_policy = {
            filter = "(user.extensionAttribute3 -eq \"FTE\") and (user.usageLocation -eq \"US\") and (user.jobTitle -startsWith \"Manager\")"
          }
        }
      ]
    }
  ]
}
