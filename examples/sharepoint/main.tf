# SharePoint site resources example.
#
# Pass SharePoint site path SUFFIXES (the part after /sites/) plus a sharepoint_base_url;
# the module onboards each site to the catalog and attaches its Members (access_type =
# "Member") or Owners (access_type = "Owner") permission group to the access package.
#
# The package association is created natively by
# azuread_access_package_resource_package_association (requires the azuread provider with
# SharePointOnline support, hashicorp/terraform-provider-azuread#1880). Catalog onboarding
# still runs through a null_resource/local-exec, so the apply host needs bash, curl, jq and
# ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID in the environment.

module "entitlement_catalog" {
  source  = "Jeenil/identity-governance/azuread"
  version = "~> 1.0"

  entitlement_catalogs = [
    {
      display_name = "marketing"
      description  = "Marketing SharePoint access"

      access_packages = [
        {
          display_name         = "brand-site-members"
          description          = "Member access to the Brand Designs and Brand Assets sites"
          access_type          = "Member"
          sharepoint_resources = ["BrandDesigns", "BrandAssets"]
          sharepoint_base_url  = "https://contoso.sharepoint.com/sites"
        },
        {
          display_name         = "brand-site-owners"
          description          = "Owner access to the Brand Designs and Brand Assets sites"
          access_type          = "Owner"
          sharepoint_resources = ["BrandDesigns", "BrandAssets"]
          sharepoint_base_url  = "https://contoso.sharepoint.com/sites"
        }
      ]
    }
  ]
}
