# SharePoint Example

Member and owner access to SharePoint sites, passed by path suffix
(`sharepoint_resources`) plus a shared `sharepoint_base_url`. The module resolves each
site's Members / Owners permission group automatically from `access_type`.

The package association is created natively by
`azuread_access_package_resource_package_association`
([hashicorp/terraform-provider-azuread#1880](https://github.com/hashicorp/terraform-provider-azuread/pull/1880)).
Catalog onboarding still uses a `null_resource` `local-exec`, so the apply host needs
`bash`, `curl`, `jq`, and `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` set.
Until the patched provider release ships, point `azuread` at the local build with a
`dev_override` — see the TEMP-wiring notes in the repo root.
