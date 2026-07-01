###   Local Variable - Identity Governance Source Variable transformation
############################################################################
locals {

  # Flat map of all access packages keyed by "catalog-package".
  # Used as the base for resource resolution and filter assembly below.
  _packages_flat = {
    for pair in flatten([
      for catalog in var.entitlement_catalogs : [
        for pkg in catalog.access_packages : {
          key     = "${catalog.display_name}-${pkg.display_name}"
          catalog = catalog.display_name
          pkg     = pkg
        }
      ]
    ]) : pair.key => pair
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
  # Otherwise build the filter from dept_code, dept_name, exclude_title_prefixes,
  # and include_title_prefixes. Null when auto_assignment_policy is not set.
  _resolved_filter = {
    for key, pair in local._packages_flat :
    key => pair.pkg.auto_assignment_policy == null ? null : (
      pair.pkg.auto_assignment_policy.filter != null
      ? pair.pkg.auto_assignment_policy.filter
      : join(" and ", compact([

        # dept match — dept_code and dept_name OR'd together, wrapped in parens
        length(compact([
          pair.pkg.auto_assignment_policy.dept_code != null ? "(user.extensionAttribute1 -eq \"${pair.pkg.auto_assignment_policy.dept_code}\")" : "",
          pair.pkg.auto_assignment_policy.dept_name != null ? "(user.department -eq \"${pair.pkg.auto_assignment_policy.dept_name}\")" : "",
        ])) > 0
        ? "(${join(" or ", compact([
          pair.pkg.auto_assignment_policy.dept_code != null ? "(user.extensionAttribute1 -eq \"${pair.pkg.auto_assignment_policy.dept_code}\")" : "",
          pair.pkg.auto_assignment_policy.dept_name != null ? "(user.department -eq \"${pair.pkg.auto_assignment_policy.dept_name}\")" : "",
        ]))})"
        : null,

        # exclude_title_prefixes — AND'd NOT conditions (member package pattern)
        length(pair.pkg.auto_assignment_policy.exclude_title_prefixes) > 0
        ? join(" and ", [
          for prefix in pair.pkg.auto_assignment_policy.exclude_title_prefixes :
          "(not (user.jobTitle -startsWith \"${prefix}\"))"
        ])
        : null,

        # include_title_prefixes — OR'd together, wrapped in parens (owner package pattern)
        length(pair.pkg.auto_assignment_policy.include_title_prefixes) > 0
        ? "(${join(" or ", [
          for prefix in pair.pkg.auto_assignment_policy.include_title_prefixes :
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
