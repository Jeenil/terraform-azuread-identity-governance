# terraform-azuread-identity-governance

Terraform module for Azure AD Entitlement Management. A superset of
[fortytwoservices/terraform-azuread-entitlement-management](https://github.com/fortytwoservices/terraform-azuread-entitlement-management)
that adds display name resolution, per-package role type, SharePoint path suffix support,
and structured OData filter assembly for auto-assignment policies.

## Features

- **Display name resolution** - pass Entra group and Teams team display names directly; the module resolves them to object IDs via data source
- **Per-package `access_type`** - set a role once at the package level and it fans out to all resources in that package. `"Member"` or `"Owner"` for `AadGroup` and `SharePointOnline` resources (resolved to the site Members/Owners permission group automatically), a role UUID for `AadApplication` resources
- **SharePoint resources** - pass site path suffixes (`"BrandDesigns"`) with a `sharepoint_base_url` instead of constructing full origin IDs manually
- **Idempotent SharePoint catalog onboarding** - catalog-level associations are handled via `null_resource` + `local-exec` that checks via Graph API before POSTing; avoids `ResourceAlreadyOnboarded` errors on subsequent applies
- **Structured OData filters** - use `dept_code`, `dept_name`, `exclude_title_prefixes`, and `include_title_prefixes` to build auto-assignment filters without writing raw OData
- **Raw filter escape hatch** - set `filter` directly for any custom OData expression; structured fields are ignored when this is set
- **Raw resource escape hatch** - pass `resources` directly with object IDs when display name resolution is not needed

## Usage

### Basic

Single access package with group display name, no auto-assignment:

```hcl
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
```

### Member and owner split with auto-assignment

Two packages with the same resource list, each granting a different role. Both packages repeat the
resource list - each package owns its own resource associations in Entra. The module makes this
concise: you repeat display names instead of full resource objects with raw object IDs, and `access_type`
is set once at the package level rather than on every resource object. Per-resource role overrides are
still available via the `resources` escape hatch when needed. The structured filter fields build the
OData expression automatically:

```hcl
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
          sharepoint_resources = ["EngineeringDocs"]
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
          sharepoint_resources = ["EngineeringDocs"]
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
```

### Raw OData filter

Use any valid Entra OData expression directly when the structured fields don't cover your attribute set:

```hcl
auto_assignment_policy = {
  filter = "(user.extensionAttribute3 -eq \"FTE\") and (user.usageLocation -eq \"US\")"
}
```

### Raw resources escape hatch

Pass resource objects with object IDs directly - works identically to the upstream module:

```hcl
resources = [
  {
    resource_origin_system = "AadGroup"
    resource_origin_id     = "00000000-0000-0000-0000-000000000000"
    access_type            = "Member"
  }
]
```

## OData filter assembly

When using structured fields, the module builds the filter as follows:

| Field | OData produced |
| --- | --- |
| `dept_code = "441000"` | `(user.extensionAttribute1 -eq "441000")` |
| `dept_name = "Engineering"` | `(user.department -eq "Engineering")` |
| Both `dept_code` and `dept_name` | `((user.extensionAttribute1 -eq "441000") or (user.department -eq "Engineering"))` |
| `exclude_title_prefixes = ["Director"]` | `(not (user.jobTitle -startsWith "Director"))` AND'd to dept match |
| `include_title_prefixes = ["Director"]` | `(user.jobTitle -startsWith "Director")` OR'd, AND'd to dept match |

Setting the raw `filter` field overrides all structured fields.

## Requirements

| Name | Version |
| --- | --- |
| terraform | >= 1.4.6 |
| azuread | >= 2.39.0 |
| msgraph | >= 0.3.0 |
| null | >= 3.0.0 |

### SharePoint catalog onboarding

SharePoint site catalog associations are created via a `null_resource` `local-exec` provisioner.
The machine running `terraform apply` must have:

- `bash`, `curl`, `jq` available on `$PATH`
- `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` set in the environment

These are the same credentials used by the `azuread` provider and are set automatically when
using the standard Azure pipeline authentication pattern (`ARM_*` environment variables).

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `connected_organizations` | Connected organizations for access package policies | `list(object)` | `[]` | no |
| `entitlement_catalogs` | Entitlement catalogs, access packages, and policies | `list(object)` | - | yes |

### Access package fields

| Name | Description | Default |
| --- | --- | --- |
| `display_name` | Access package display name | required |
| `description` | Access package description | - |
| `group_resources` | Entra group display names - resolved to object IDs | `[]` |
| `teams_resources` | Teams team display names - resolved to M365 group object IDs | `[]` |
| `sharepoint_resources` | SharePoint site path suffixes e.g. `"BrandDesigns"` | `[]` |
| `sharepoint_base_url` | Base SharePoint URL - required when `sharepoint_resources` is non-empty | `""` |
| `access_type` | Role granted on all resources in this package. `"Member"` or `"Owner"` for `AadGroup` and `SharePointOnline` (resolved to the site Members/Owners permission group); role UUID for `AadApplication` | `"Member"` |
| `sharepoint_role_origin_id` | SharePoint permission group originId to filter the role lookup e.g. `"3"` for the Owners group (SP default). When `null`, uses the first role returned (Members). Set on owner packages to guarantee the Owners role is selected regardless of site group ordering. | `null` |
| `resources` | Raw resource objects - escape hatch, overrides display-name inputs if non-empty | `[]` |
| `auto_assignment_policy` | Auto-assignment policy configuration | `null` |

### Auto-assignment policy fields

| Name | Description | Default |
| --- | --- | --- |
| `filter` | Raw OData expression - overrides all structured fields below | `null` |
| `dept_code` | `extensionAttribute1` value e.g. `"441000"` | `null` |
| `dept_name` | Department display name e.g. `"Engineering"` | `null` |
| `exclude_title_prefixes` | `jobTitle -startsWith` values to exclude (member package pattern) | `[]` |
| `include_title_prefixes` | `jobTitle -startsWith` values to include (owner package pattern) | `[]` |
| `remove_when_target_leaves` | Revoke access when user no longer matches the filter | `true` |
| `grace_period_before_removal` | ISO 8601 grace period before revoking access | `"P7D"` |

## Outputs

| Name | Description |
| --- | --- |
| `entitlement_catalogs` | All entitlement catalogs created by this module |
| `access_packages` | All access packages created by this module |
| `assignment_policies` | All access package assignment policies created by this module |
| `resource_catalog_associations` | All resources associated with entitlement catalogs |
| `resource_access_package_associations` | All resources associated with access packages |

## Why not use fortytwoservices/terraform-azuread-entitlement-management?

The upstream module is a solid foundation and this module builds directly on it. The primary reason for this module is **catalog resource association deduplication** - if you put two packages in the same catalog that share the same resources (the typical Member + Owner split), the upstream module tries to create duplicate catalog resource associations for the same resource, which fails.
This module deduplicates catalog associations so a resource is registered with the catalog once and each package gets its own package-level association at the correct role.

Additional gaps covered:

| Capability | fortytwoservices | this module |
| --- | --- | --- |
| **Member + Owner packages sharing resources** in one catalog | No | Yes - deduplicates catalog associations |
| Group / Teams resources by **display name** | No - requires raw object IDs | Yes - resolves display names to object IDs internally |
| **Per-package `access_type`** | No - role must be set per resource object | Yes - set once at the package level, fans out to all resources; `"Owner"` grants SP site Owners permission group for SharePoint resources |
| **SharePoint** by path suffix | No - requires full origin ID | Yes - `sharepoint_resources` + `sharepoint_base_url` |
| **Idempotent SharePoint catalog onboarding** | No - `ResourceAlreadyOnboarded` on subsequent applies | Yes - `null_resource` local-exec checks via Graph before POSTing |
| **Structured OData filters** | No - raw filter string only | Yes - `dept_code`, `dept_name`, `include/exclude_title_prefixes`; raw `filter` still works as an escape hatch |

## Known Limitations and Roadmap

### Catalog resource association removal

Removing a SharePoint resource from a catalog is not currently supported. The `null_resource`
`local-exec` provisioner only runs on create — Terraform has no mechanism to issue a Graph API
DELETE for catalog associations on destroy. Removing a SharePoint resource from your config will
leave the catalog association in Entra until it is deleted manually via the portal or Graph API.

Tracking: [hashicorp/terraform-provider-azuread#1637](https://github.com/hashicorp/terraform-provider-azuread/issues/1637)

Once the `azuread` provider adds native support for catalog resource associations this module will
be updated to use it, enabling full create and destroy lifecycle management.

### Planned improvements

- Native catalog association removal once provider support lands
- `outputs.tf` - expose catalog IDs, access package IDs, and policy IDs for use in downstream modules

## Reference

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->

## Credits

This module builds on [terraform-azuread-entitlement-management](https://github.com/fortytwoservices/terraform-azuread-entitlement-management)
by [fortytwoservices](https://github.com/fortytwoservices), used under the MIT License.
The catalog, access package, approval, and access review resource foundations originate from that module.
