###   Local Variable - Identity Governance Source Variable transformation
############################################################################
locals {

  # Flat map of all access packages keyed by "catalog-package".
  # Owner packages (is_owner_package = true) are excluded when the catalog sets
  # create_owners_package = false, so all downstream locals and resources automatically
  # skip them without extra guards.
  _packages_flat = {
    for pair in flatten([
      for catalog in var.entitlement_catalogs : [
        for pkg in catalog.access_packages : {
          key                               = "${catalog.display_name}-${pkg.display_name}"
          catalog                           = catalog.display_name
          pkg                               = pkg
          catalog_dept_code                 = catalog.dept_code
          catalog_dept_name                 = catalog.dept_name
          catalog_management_title_prefixes = catalog.management_title_prefixes
          catalog_create_owners_package     = catalog.create_owners_package
        }
      ]
    ]) : pair.key => pair
    if !(pair.pkg.auto_assignment_policy != null && pair.pkg.auto_assignment_policy.is_owner_package && !pair.catalog_create_owners_package)
  }

  # Pre-compute effective OData filter values per package, merging catalog-level defaults
  # with package-level overrides and is_owner_package logic. Used only in _resolved_filter.
  #
  # Resolution order for dept values:  package-level > catalog-level > null
  # Resolution order for title prefixes:
  #   - Explicit package-level exclude/include lists always win.
  #   - Otherwise, catalog management_title_prefixes are applied:
  #       is_owner_package = false → exclude them  (member pattern: all dept minus leadership)
  #       is_owner_package = true  → include them  (owner pattern: leadership only)
  _packages_enriched = {
    for key, pair in local._packages_flat :
    key => merge(pair, {
      effective_dept_code = (
        pair.pkg.auto_assignment_policy != null && pair.pkg.auto_assignment_policy.dept_code != null
        ? pair.pkg.auto_assignment_policy.dept_code
        : pair.catalog_dept_code
      )
      effective_dept_name = (
        pair.pkg.auto_assignment_policy != null && pair.pkg.auto_assignment_policy.dept_name != null
        ? pair.pkg.auto_assignment_policy.dept_name
        : pair.catalog_dept_name
      )
      # Effective exclude list: package explicit > catalog prefixes for member packages
      effective_title_excludes = (
        pair.pkg.auto_assignment_policy == null ? [] :
        length(pair.pkg.auto_assignment_policy.exclude_title_prefixes) > 0
        ? pair.pkg.auto_assignment_policy.exclude_title_prefixes
        : (!pair.pkg.auto_assignment_policy.is_owner_package ? pair.catalog_management_title_prefixes : [])
      )
      # Effective include list: package explicit > catalog prefixes for owner packages
      effective_title_includes = (
        pair.pkg.auto_assignment_policy == null ? [] :
        length(pair.pkg.auto_assignment_policy.include_title_prefixes) > 0
        ? pair.pkg.auto_assignment_policy.include_title_prefixes
        : (pair.pkg.auto_assignment_policy.is_owner_package ? pair.catalog_management_title_prefixes : [])
      )
    })
  }

  # ── Resource list resolution ────────────────────────────────────────────────
  # If resources is non-empty use it directly (escape hatch).
  # Otherwise build from group_resources, teams_resources, sharepoint_resources.
  # All resolved resources inherit the package-level access_type.
  _resolved_resources = {
    for key, pair in local._packages_flat :
    key => length(pair.pkg.resources) > 0 ? pair.pkg.resources : concat(
      [for g in pair.pkg.group_resources : {
        display_name           = g
        resource_origin_system = "AadGroup"
        resource_origin_id     = data.azuread_group.groups[g].object_id
        access_type            = pair.pkg.access_type
      }],
      [for t in pair.pkg.teams_resources : {
        display_name           = t
        resource_origin_system = "AadGroup"
        resource_origin_id     = data.msgraph_resource.teams_groups[t].output.id
        access_type            = pair.pkg.access_type
      }],
      [for s in pair.pkg.sharepoint_resources : {
        display_name           = s
        resource_origin_system = "SharePointOnline"
        resource_origin_id     = "${trimsuffix(pair.pkg.sharepoint_base_url, "/")}/${s}"
        access_type            = pair.pkg.access_type
      }]
    )
  }

  # ── OData filter assembly ───────────────────────────────────────────────────
  # If raw filter is set, pass it through unchanged — structured fields are ignored.
  # Otherwise build the filter from effective dept/title values resolved in _packages_enriched.
  # Null when auto_assignment_policy is not set on the package.
  _resolved_filter = {
    for key, pair in local._packages_enriched :
    key => pair.pkg.auto_assignment_policy == null ? null : (
      pair.pkg.auto_assignment_policy.filter != null
      ? pair.pkg.auto_assignment_policy.filter
      : join(" and ", compact([

        # dept match — effective_dept_code and effective_dept_name OR'd together, wrapped in parens
        length(compact([
          pair.effective_dept_code != null ? "(user.extensionAttribute1 -eq \"${pair.effective_dept_code}\")" : "",
          pair.effective_dept_name != null ? "(user.department -eq \"${pair.effective_dept_name}\")" : "",
        ])) > 0
        ? "(${join(" or ", compact([
          pair.effective_dept_code != null ? "(user.extensionAttribute1 -eq \"${pair.effective_dept_code}\")" : "",
          pair.effective_dept_name != null ? "(user.department -eq \"${pair.effective_dept_name}\")" : "",
        ]))})"
        : null,

        # Member pattern: exclude management/leadership titles
        length(pair.effective_title_excludes) > 0
        ? join(" and ", [
          for prefix in pair.effective_title_excludes :
          "(not (user.jobTitle -startsWith \"${prefix}\"))"
        ])
        : null,

        # Owner pattern: include only management/leadership titles
        length(pair.effective_title_includes) > 0
        ? "(${join(" or ", [
          for prefix in pair.effective_title_includes :
          "(user.jobTitle -startsWith \"${prefix}\")"
        ])})"
        : null,

      ]))
    )
  }

  # ── Upstream locals — updated to use resolved resources and filter ──────────

  entitlement-catalogs = flatten([
    for catalog in var.entitlement_catalogs : catalog
  ])

  # Resolves to the Entra catalog ID regardless of whether this state created it or looked it up.
  catalog_ids = {
    for catalog in local.entitlement-catalogs : catalog.display_name =>
    catalog.create_catalog
    ? azuread_access_package_catalog.entitlement-catalogs[catalog.display_name].id
    : data.azuread_access_package_catalog.existing[catalog.display_name].id
  }

  access-packages = flatten([
    for catalog in var.entitlement_catalogs : [
      for ap in catalog.access_packages : merge(ap, {
        catalog_key = catalog.display_name
        key         = "${catalog.display_name}-${ap.display_name}"
        auto_assignment_policy = ap.auto_assignment_policy == null ? null : merge(ap.auto_assignment_policy, {
          filter = local._resolved_filter["${catalog.display_name}-${ap.display_name}"]
        })
      })
      if contains(keys(local._packages_flat), "${catalog.display_name}-${ap.display_name}")
    ]
  ])

  # Flat list of one-off direct user assignments, one object per (package, user).
  # Drives null_resource.direct-assignments, which AdminAdds each user to the package
  # and AdminRemoves them when the entry is dropped from the config.
  direct-assignments = flatten([
    for catalog in var.entitlement_catalogs : [
      for ap in catalog.access_packages : [
        for upn in ap.direct_assignments : {
          key                 = "${catalog.display_name}-${ap.display_name}-${upn}"
          access_package_key  = "${catalog.display_name}-${ap.display_name}"
          user_principal_name = upn
        }
      ]
      if contains(keys(local._packages_flat), "${catalog.display_name}-${ap.display_name}")
    ]
  ])

  resources = flatten([
    for catalog in var.entitlement_catalogs : [
      for ap in catalog.access_packages : [
        for resource in local._resolved_resources["${catalog.display_name}-${ap.display_name}"] : merge(resource, {
          catalog_key                             = catalog.display_name
          access_package_key                      = "${catalog.display_name}-${ap.display_name}"
          access_package_resource_association_key = "${catalog.display_name}-${ap.display_name}-${resource.display_name != null ? resource.display_name : "${resource.resource_origin_system}-${resource.resource_origin_id}-${resource.access_type}"}"
          catalog_resource_association_key        = "${catalog.display_name}-${resource.display_name != null ? resource.display_name : "${resource.resource_origin_system}-${resource.resource_origin_id}-${resource.access_type}"}"
        })
      ]
      if contains(keys(local._packages_flat), "${catalog.display_name}-${ap.display_name}")
    ]
  ])

  resource-catalog-associations-filtered = [
    for resource in values(zipmap(local.resources[*].catalog_resource_association_key, local.resources)) : resource
    if resource.resource_origin_system != "SharePointOnline"
  ]

  sharepoint-catalog-associations-filtered = [
    for resource in values(zipmap(local.resources[*].catalog_resource_association_key, local.resources)) : resource
    if resource.resource_origin_system == "SharePointOnline"
  ]

  _dynamic_teams_groups = {
    for name, group in data.msgraph_resource.teams_groups :
    name => tostring(group.output.membership_rule)
    if tostring(group.output.membership_rule_processing_state) == "On"
  }

  # Intermediate: filtered role list per SharePoint resource key before the [0] guard below.
  # Without this split, an empty match (e.g. access_type drift or missing permission group)
  # would panic with a cryptic index-out-of-range instead of a readable message.
  # Example: if access_type = "Owner" but the site has no "AccountManagers Owners" group,
  # the guard fires: "No SharePoint role ending with ' owners' found for access package
  # 'onboarding-access-package-department-X'. Check access_type and that the site's
  # permission groups exist."
  _sp_filtered_roles = {
    for key, resource in { for r in local.resources : r.access_package_resource_association_key => r if r.resource_origin_system == "SharePointOnline" } :
    key => [
      for role in data.msgraph_resource.sharepoint_catalog_resource_roles[key].output.all.value :
      role if endswith(lower(tostring(role["displayName"])), resource.access_type == "Owner" ? " owners" : " members")
    ]
  }

  # Pick the correct SP permission group role for each access package association.
  # Filters the full role list returned by the data source by matching the display name
  # suffix — "Owners" for owner packages, "Members" for member packages.
  # This avoids hardcoding originId values and works regardless of role list ordering.
  _sp_selected_role = {
    for key, resource in { for r in local.resources : r.access_package_resource_association_key => r if r.resource_origin_system == "SharePointOnline" } :
    key => length(local._sp_filtered_roles[key]) > 0 ? local._sp_filtered_roles[key][0] : tobool(
      "No SharePoint role ending with '${resource.access_type == "Owner" ? " owners" : " members"}' found for access package '${key}'. Check access_type and that the site's permission groups exist."
    )
  }
}
