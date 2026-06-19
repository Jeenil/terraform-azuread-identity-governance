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
- **Idempotent auto-assignment policies** - same check-before-create pattern; avoids duplicate policy errors or stale state issues if the policy already exists in Azure
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

### SharePoint catalog onboarding

SharePoint site catalog associations are created via a `null_resource` `local-exec` provisioner.
The machine running `terraform apply` must have:

- `bash`, `curl`, `jq` available on `$PATH`
- `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` set in the environment

These are the same credentials used by the `azuread` provider and are set automatically when
using the standard Azure pipeline authentication pattern (`ARM_*` environment variables).

### Auto-assignment policy creation

Auto-assignment policies are also created via `null_resource` + `local-exec` using the same
check-before-create pattern. On each apply the provisioner queries the Graph API for an existing
auto-assignment policy on the access package - skips if one is found, creates if not. The same
`bash`, `curl`, `jq`, and `ARM_*` requirements apply.

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
| **Idempotent auto-assignment policy creation** | No | Yes - `null_resource` local-exec checks via Graph before POSTing; safe to re-apply after any state manipulation |
| **Structured OData filters** | No - raw filter string only | Yes - `dept_code`, `dept_name`, `include/exclude_title_prefixes`; raw `filter` still works as an escape hatch |

## Known Limitations and Roadmap

### Catalog resource association removal

Removing a SharePoint resource from a catalog is not currently supported. The `null_resource`
`local-exec` provisioner only runs on create - Terraform has no mechanism to issue a Graph API
DELETE for catalog associations on destroy. Removing a SharePoint resource from your config will
leave the catalog association in Entra until it is deleted manually via the portal or Graph API.

Tracking: [hashicorp/terraform-provider-azuread#1637](https://github.com/hashicorp/terraform-provider-azuread/issues/1637)

Once the `azuread` provider adds native support for catalog resource associations this module will
be updated to use it, enabling full create and destroy lifecycle management.

### Graph API 429 throttling on plans with SharePoint resources

When this module is used with `sharepoint_resources`, each SharePoint site requires two
sequential `data "msgraph_resource"` lookups per access package (catalog resource lookup, then role lookup).
Terraform fires all of these in parallel by default. With more than a handful of SharePoint
resources in a single state file, the Identity Governance endpoint returns `429 Too Many Requests`.

The `microsoft/msgraph` provider retries on 429 but the azure-sdk `MaxRetryDelay` defaults to
60 s. The Identity Governance endpoint returns `Retry-After` values up to 315 s, so the SDK
retries too early, re-hits 429, and exhausts its attempts before the throttle window clears.

**Workaround:** pass `-parallelism=1` to `terraform plan` to force sequential data source
reads. This avoids hitting the rate limit entirely at the cost of slower plans.

```bash
terraform plan -parallelism=1
```

**Tracking:** [microsoft/terraform-provider-msgraph#118](https://github.com/microsoft/terraform-provider-msgraph/issues/118) - fix in [PR #119](https://github.com/microsoft/terraform-provider-msgraph/pull/119)

**Structural improvement:** split your Terraform state so each root module manages one catalog.
Each plan then only reads data sources for the catalog that changed (~5 calls vs ~30), reducing
the chance of hitting the rate limit. `-parallelism=1` is still required until
[PR #119](https://github.com/microsoft/terraform-provider-msgraph/pull/119) is merged and the
provider version is bumped - once it is, the parallelism override can be removed.

### Planned improvements

- Native catalog association removal once provider support lands
- `outputs.tf` - expose catalog IDs, access package IDs, and policy IDs for use in downstream modules

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >=1.4.6 |
| <a name="requirement_azuread"></a> [azuread](#requirement\_azuread) | >=2.39.0 |
| <a name="requirement_msgraph"></a> [msgraph](#requirement\_msgraph) | >=0.3.0 |
| <a name="requirement_null"></a> [null](#requirement\_null) | >=3.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azuread"></a> [azuread](#provider\_azuread) | >=2.39.0 |
| <a name="provider_msgraph"></a> [msgraph](#provider\_msgraph) | >=0.3.0 |
| <a name="provider_null"></a> [null](#provider\_null) | >=3.0.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Resources

| Name | Type |
|------|------|
| [azuread_access_package.access-packages](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/access_package) | resource |
| [azuread_access_package_assignment_policy.assignment_policies](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/access_package_assignment_policy) | resource |
| [azuread_access_package_catalog.entitlement-catalogs](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/access_package_catalog) | resource |
| [azuread_access_package_resource_package_association.resource-access-package-associations](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/access_package_resource_package_association) | resource |
| [msgraph_resource.auto-assignment-policies](https://registry.terraform.io/providers/microsoft/msgraph/latest/docs/resources/resource) | resource |
| [msgraph_resource.connected_organizations](https://registry.terraform.io/providers/microsoft/msgraph/latest/docs/resources/resource) | resource |
| [msgraph_resource_action.resource-access-package-associations](https://registry.terraform.io/providers/microsoft/msgraph/latest/docs/resources/resource_action) | resource |
| [msgraph_resource_action.sharepoint-access-package-associations](https://registry.terraform.io/providers/microsoft/msgraph/latest/docs/resources/resource_action) | resource |
| [null_resource.catalog-associations](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.sharepoint-catalog-associations](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [terraform_data.force-remove-assignments](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.validate_teams_not_dynamic](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_entitlement_catalogs"></a> [entitlement\_catalogs](#input\_entitlement\_catalogs) | A nested list of objects describing Access Packages, it's parent Catalogs, Assignment Policies and associated resources | <pre>list(object({                         # List of Entitlement Catalogs, one object for each catalog<br/>    display_name       = string                # Name of the Entitlement Catalog<br/>    description        = optional(string)      # Description of the Entitlement Catalog<br/>    externally_visible = optional(bool, false) # If the Entitlement Catalog should be visible outside of the Azure Tenant. true, false. Defaults to "false"<br/>    published          = optional(bool, true)  # If the Access Packages in this catalog are available for management. true, false. Defaults to "true"<br/>    create_catalog     = optional(bool, true)  # When false, look up an existing catalog by display_name instead of creating one. Use when multiple states share one catalog.<br/><br/>    access_packages = list(object({<br/>      display_name      = string                # Name of the Access Package<br/>      description       = optional(string)      # Description of the Access Package<br/>      hidden            = optional(bool, false) # If the Access Package should be hidden from the requestor<br/>      duration_in_days  = optional(number)      # How many days the assignment is valid for. Conflicts with "expiration_date"<br/>      expiration_date   = optional(string)      # The date that this assignment expires, in RFC3339 format. Conflicts with "duration_in_days"<br/>      extension_enabled = optional(bool, true)  # Whether users will be able to request extension before it expires. true, false. Defaults to true<br/>      requests_accepted = optional(bool, true)  # Whether to accept requests using this policy. When false, no new requests can be made using this policy. true, false. Defaults to true<br/>      scope_type        = optional(string)      # Deprecated! Use the setting in requestor_settings.scope_type. Specifies the scopes of the requestors. AllConfiguredConnectedOrganizationSubjects, AllExistingConnectedOrganizationSubjects, AllExistingDirectoryMemberUsers, AllExistingDirectorySubjects, AllExternalSubjects, NoSubjects, SpecificConnectedOrganizationSubjects, or SpecificDirectorySubjects Defaults to "AllExistingDirectoryMemberUsers".<br/><br/>      # Specified requestor requires scope_type SpecificDirectorySubjects or SpecificConnectedOrganizationSubjects. Defaults to SpecificDirectorySubjects.<br/>      requestor_settings = optional(object({                                    # A block specifying the users who are allowed to request on this policy<br/>        requests_accepted = optional(bool)                                      # Whether to accept requests using this policy. When false, no new requests can be made using this policy.<br/>        scope_type        = optional(string, "AllExistingDirectoryMemberUsers") # A Specifies the scope of the requestors. Valid values are AllConfiguredConnectedOrganizationSubjects, AllExistingConnectedOrganizationSubjects, AllExistingDirectoryMemberUsers, AllExistingDirectorySubjects, AllExternalSubjects, NoSubjects, SpecificConnectedOrganizationSubjects, or SpecificDirectorySubjects.<br/><br/>        requestor = optional(object({<br/>          subject_type               = string           # Specifies the type of users. Valid values are singleUser, groupMembers, connectedOrganizationMembers, requestorManager, internalSponsors or externalSponsors<br/>          object_id                  = optional(string) # The ID of the subject<br/>          connected_organization_key = optional(string) # The key of the connected organization, required if you want to match connected organization created in this module.<br/>        }))<br/>        }),<br/>        {<br/>          scope_type = "AllExistingDirectoryMemberUsers" # Defaults the requestor_settings value to use AllExistingDirectoryMemberUsers.<br/>        }<br/>      )<br/><br/>      approval_required                   = optional(bool, true)  # Whether an approval is required. true, false. Defaults to true<br/>      approval_required_for_extension     = optional(bool, false) # Whether approval is required to grant extension. Same approval settings used to approve initial access will apply. true, false. Defaults to false<br/>      requestor_justification_required    = optional(bool, false) # Whether a requestor is required to provide a justification to request an access package. true, false. Defaults to false<br/>      approval_timeout_in_days            = optional(number, 14)  # Maximum number of days within which a request most be approved. Defaults to 14<br/>      approver_justification_required     = optional(bool, false) # Whether an approver must provide a justification for their decision. Defaults to "false"<br/>      alternative_approval_enabled        = optional(bool, false) # Whether alternative approvers are enabled. Defaults to false<br/>      enable_alternative_approval_in_days = optional(number)      # Number of days before the request is forwarded to alternative approvers<br/><br/>      primary_approvers = optional(list(object({ # A list of objects, with one object for each Primary Approver<br/>        subject_type = string                    # Specifies the type of user. singleUser, groupMembers, connectedOrganizationMembers, requestorManager, internalSponsors, or externalSponsors<br/>        object_id    = string                    # Object ID of the Primary Approver<br/>        backup       = optional(bool, false)     # For a user in an approval stage, this property indicates whether the user is a backup fallback appover<br/>      })))<br/><br/>      alternative_approvers = optional(list(object({<br/>        subject_type = string                # Type of approver. "singleUser", "groupMembers", "connectedOrganizationMembers", "requestorManager", "internalSponsors", "externalSponsors"<br/>        object_id    = string                # Object ID of the Primary Approver<br/>        backup       = optional(bool, false) # For a user in an approval stage, this property indicates whether the user is a backup fallback appover<br/>      })))<br/><br/>      assignment_review_settings = optional(object({<br/>        enabled                         = optional(bool, true)             # Whether the assignment should be enabled or not. Defaults to true<br/>        review_frequency                = optional(string, "annual")       # How ofter reviews should happen. weekly, monthly, quarterly, halfyearly, annual. Defaults to annual<br/>        duration_in_days                = optional(number, 14)             # How many days each occurrence of the access review series will run. Defaults to 14<br/>        review_type                     = optional(string, "Self")         # Self review or specify reviewers. "Self", "Reviewers". Defaults to "self"<br/>        access_review_timeout_behavior  = optional(string, "removeAccess") # What happens if access review times out. "keepAccess", "removeAccess", "acceptAccessRecommendation". Defaults to "removeAccess"<br/>        approver_justification_required = optional(bool, false)            # Whether a reviewer needs to provide a justification for their decision<br/><br/>        reviewers = list(object({              # List of reviewers. One object per reviewer<br/>          subject_type = string                # Type of reviewer. "singleUser", "groupMembers", "connectedOrganizationMembers", "requestorManager", "internalSponsors", "externalSponsors"<br/>          object_id    = string                # Object ID of the reviewer<br/>          backup       = optional(bool, false) # Indicates whether the user is a backup approver or not. "true", "false". Defaults to "false".<br/>        }))<br/>      }))<br/><br/>      question = optional(list(object({      # A list of questions. One object per question<br/>        required     = optional(bool, false) # Whether this question is requried. true, false. Defaults to false<br/>        sequence     = number                # The sequence number of this question<br/>        default_text = string                # The default text of this question<br/><br/>        choice = optional(list(object({   # List of choices for multiple choice. One object per choice<br/>          default_text = string           # The default text of this question choice<br/>          actual_value = optional(string) # The actual value of this choice. Defaults to default_text value<br/>        })))<br/>      })))<br/><br/>      group_resources      = optional(list(string), []) # Entra ID security/M365 group display names :resolved to object IDs via data source<br/>      teams_resources      = optional(list(string), []) # Teams team display names :resolved to the backing M365 group object IDs via data source<br/>      sharepoint_resources = optional(list(string), []) # SharePoint site path suffixes e.g. "BrandDesigns" for /sites/BrandDesigns :requires sharepoint_base_url<br/>      sharepoint_base_url  = optional(string, "")       # Base SharePoint URL e.g. "https://contoso.sharepoint.com/sites" :required when sharepoint_resources is non-empty<br/>      access_type          = optional(string, "Member") # Role granted on all resolved resources in this package. "Member" or "Owner". Defaults to "Member"<br/><br/>      auto_assignment_policy = optional(object({<br/>        filter                      = optional(string)           # Raw OData :if set, all structured fields below are ignored<br/>        dept_code                   = optional(string)           # extensionAttribute1 value e.g. "441000" :ignored if filter is set<br/>        dept_name                   = optional(string)           # Department display name e.g. "Engineering" :ignored if filter is set<br/>        exclude_title_prefixes      = optional(list(string), []) # jobTitle -startsWith values to EXCLUDE :ignored if filter is set (member package pattern)<br/>        include_title_prefixes      = optional(list(string), []) # jobTitle -startsWith values to INCLUDE :ignored if filter is set (owner package pattern)<br/>        remove_when_target_leaves   = optional(bool, true)       # Revoke access when the user no longer matches the filter. Defaults to true<br/>        grace_period_before_removal = optional(string, "P7D")    # ISO 8601 duration to wait before revoking access after a user leaves scope. Defaults to 7 days<br/>      }))<br/><br/>      resources = optional(list(object({                    # Escape hatch :pass raw resource objects directly. Overrides group/teams/sharepoint_resources if non-empty<br/>        display_name           = optional(string)           # Deprecated! Descriptive display name to be used for the Terraform Resource key<br/>        resource_origin_system = string                     # The type of resource in the origin system. "SharePointOnline", "AadApplication", "AadGroup"<br/>        resource_origin_id     = string                     # The ID of the Azure resource to be added to the Catalog and Access Package<br/>        access_type            = optional(string, "Member") # Per-resource role override. "Member" or "Owner" for AadGroup, role uuid for AadApplication. Defaults to "Member"<br/>      })), [])<br/>    }))<br/>  }))</pre> | n/a | yes |
| <a name="input_connected_organizations"></a> [connected\_organizations](#input\_connected\_organizations) | A list of connected organizations to be used in Access Package policies | <pre>list(object({<br/>    display_name = string            # Name of the Connected Organization.<br/>    description  = optional(string)  # Description of the Connected Organization.<br/>    identity_sources = list(object({ # A list of identity sources for the connected organization.<br/>      tenantid     = string          # The Azure AD tenant ID of the identity source. <br/>      display_name = string          # Display name for the identity source.<br/>    }))<br/>    state = optional(string, "configured") # State of the connected organization. Either "configured" or "proposed". Defaults to "configured".<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_access_packages"></a> [access\_packages](#output\_access\_packages) | Outputs all Access Packages created through this module |
| <a name="output_assignment_policies"></a> [assignment\_policies](#output\_assignment\_policies) | Outputs all Access Package Assignment Policies created through this module |
| <a name="output_auto_assignment_policies"></a> [auto\_assignment\_policies](#output\_auto\_assignment\_policies) | Auto-assignment policies managed through this module, keyed by "<catalog>-<package>". Exposes the live policy id and membership rule (resolved OData filter) for downstream modules and CI assertions. |
| <a name="output_catalog_ids"></a> [catalog\_ids](#output\_catalog\_ids) | Resolved Entra catalog IDs keyed by catalog display name, whether the catalog was created by this module or looked up. |
| <a name="output_entitlement_catalogs"></a> [entitlement\_catalogs](#output\_entitlement\_catalogs) | Outputs all Entitlement Catalogs created through this module |
| <a name="output_resource_access_package_associations"></a> [resource\_access\_package\_associations](#output\_resource\_access\_package\_associations) | Outputs all Resources associated with the Access Packages |
| <a name="output_resource_catalog_associations"></a> [resource\_catalog\_associations](#output\_resource\_catalog\_associations) | Outputs all Resources associated with the Entitlement Catalogs |
<!-- END_TF_DOCS -->

## Credits

This module builds on [terraform-azuread-entitlement-management](https://github.com/fortytwoservices/terraform-azuread-entitlement-management)
by [fortytwoservices](https://github.com/fortytwoservices), used under the MIT License.
The catalog, access package, approval, and access review resource foundations originate from that module.