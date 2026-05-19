module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "engineering"
      description  = "Engineering department access"

      access_packages = [
        {
          display_name    = "engineering-members"
          description     = "Standard engineering access"
          access_type     = "Member"
          group_resources = ["Engineering All Staff"]
        }
      ]
    }
  ]
}
