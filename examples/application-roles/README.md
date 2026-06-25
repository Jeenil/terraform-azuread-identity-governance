# Application (App Role) Example

Attaches an enterprise application's **app role** to an access package via the
`resources` escape hatch with `resource_origin_system = "AadApplication"`.

- `resource_origin_id` is the service principal (enterprise app) **object id**.
- `access_type` is an **app role id (UUID)** exposed by that application.

The package association is created natively by
`azuread_access_package_resource_package_association`, which requires the `azuread`
provider with `AadApplication` support
([hashicorp/terraform-provider-azuread#1880](https://github.com/hashicorp/terraform-provider-azuread/pull/1880)).
Until that release ships, point the provider at the patched build with a `dev_override`
— see the TEMP-wiring notes in the repo root.
