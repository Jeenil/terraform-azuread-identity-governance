resource "msgraph_resource" "connected_organizations" {
  for_each = { for org in var.connected_organizations : org.display_name => org }
  url      = "/identityGovernance/entitlementManagement/connectedOrganizations"

  body = {
    displayName = each.value.display_name
    description = each.value.description
    identitySources = [
      for source in each.value.identity_sources : {
        "@odata.type" = "#microsoft.graph.azureActiveDirectoryTenant"
        displayName   = source.display_name
        tenantId      = source.tenantid
      }
    ]
    state = each.value.state
  }

  response_export_values = {
    id = "id"
  }
}

###   Identity Governance - Entitlement Catalogs
###################################################
resource "azuread_access_package_catalog" "entitlement-catalogs" {
  for_each = { for catalog in local.entitlement-catalogs : catalog.display_name => catalog if catalog.create_catalog }

  display_name       = each.key
  description        = each.value.description
  externally_visible = try(each.value.externally_visible, null)
  published          = try(each.value.published, null)
}

###   Identity Governance - Access Packages
##############################################
resource "azuread_access_package" "access-packages" {
  for_each = { for ap in local.access-packages : ap.key => ap }

  catalog_id   = local.catalog_ids[each.value.catalog_key]
  display_name = each.value.display_name
  description  = each.value.description
  hidden       = try(each.value.hidden, null)

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    null_resource.catalog-associations
  ]
}

###   Identity Governance - Assignment Policies
##################################################
resource "azuread_access_package_assignment_policy" "assignment_policies" {
  for_each = { for ap in local.access-packages : ap.key => ap }

  display_name      = "${each.value.display_name}-policy"
  description       = each.value.description
  access_package_id = azuread_access_package.access-packages[each.key].id
  duration_in_days  = each.value.duration_in_days
  expiration_date   = each.value.expiration_date
  extension_enabled = each.value.extension_enabled

  requestor_settings {
    requests_accepted = each.value.requests_accepted
    scope_type        = each.value.scope_type != null ? each.value.scope_type : each.value.requestor_settings.scope_type

    dynamic "requestor" {
      for_each = toset(try(each.value.requestor_settings.requestor, null) != null ? [1] : [])

      content {
        object_id    = each.value.requestor_settings.requestor.subject_type == "connectedOrganizationMembers" ? (each.value.requestor_settings.requestor.connected_organization_key != null ? msgraph_resource.connected_organizations[each.value.requestor_settings.requestor.connected_organization_key].output.id : each.value.requestor_settings.requestor.object_id) : each.value.requestor_settings.requestor.object_id
        subject_type = each.value.requestor_settings.requestor.subject_type
      }
    }
  }

  approval_settings {
    approval_required                = each.value.approval_required
    approval_required_for_extension  = each.value.approval_required_for_extension
    requestor_justification_required = each.value.requestor_justification_required

    dynamic "approval_stage" {
      for_each = toset(each.value.approval_required ? [1] : [])

      content {
        approval_timeout_in_days            = each.value.approval_timeout_in_days
        approver_justification_required     = each.value.approver_justification_required
        alternative_approval_enabled        = each.value.alternative_approval_enabled
        enable_alternative_approval_in_days = each.value.alternative_approval_enabled ? each.value.enable_alternative_approval_in_days : null


        dynamic "primary_approver" {
          for_each = each.value.approval_required ? (each.value.primary_approvers != null ? toset(each.value.primary_approvers) : []) : []

          content {
            subject_type = primary_approver.value.subject_type
            object_id    = primary_approver.value.object_id
            backup       = primary_approver.value.backup
          }
        }

        dynamic "alternative_approver" {
          for_each = each.value.alternative_approval_enabled != null ? (each.value.alternative_approvers != null ? toset(each.value.alternative_approvers) : []) : []

          content {
            subject_type = alternative_approver.value.subject_type
            object_id    = alternative_approver.value.object_id
            backup       = alternative_approver.value.backup
          }
        }
      }
    }
  }

  dynamic "assignment_review_settings" {
    for_each = toset(try(each.value.assignment_review_settings, null) != null ? [1] : [])

    content {
      enabled                         = each.value.assignment_review_settings.enabled
      review_frequency                = each.value.assignment_review_settings.review_frequency
      duration_in_days                = each.value.assignment_review_settings.duration_in_days
      review_type                     = each.value.assignment_review_settings.review_type
      access_recommendation_enabled   = true
      access_review_timeout_behavior  = each.value.assignment_review_settings.access_review_timeout_behavior
      approver_justification_required = each.value.assignment_review_settings.approver_justification_required

      dynamic "reviewer" {
        for_each = each.value.assignment_review_settings.review_type == "Reviewers" ? { for reviewer in each.value.assignment_review_settings.reviewers : reviewer.object_id => reviewer } : {}

        content {
          object_id    = reviewer.value.object_id
          subject_type = reviewer.value.subject_type
          backup       = reviewer.value.backup
        }
      }
    }
  }

  dynamic "question" {
    for_each = toset(each.value.question != null ? each.value.question : [])

    content {
      required = question.value.required
      sequence = question.value.sequence

      text {
        default_text = question.value.default_text
      }

      dynamic "choice" {
        for_each = question.value.choice != null ? question.value.choice : []

        content {
          actual_value = choice.value.actual_value != null ? choice.value.actual_value : choice.value.default_text

          display_value {
            default_text = choice.value.default_text
          }
        }
      }
    }
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    azuread_access_package.access-packages,
    null_resource.catalog-associations,
    azuread_access_package_resource_package_association.resource-access-package-associations
  ]
}

###   Identity Governance - Auto-Assignment Policies
###   Created only when auto_assignment_policy is defined on an access package.
###   These are separate from request-based policies — Entra ID automatically grants
###   access to users matching the OData filter without requiring a request.
###
###   Managed via msgraph_resource (not null_resource) so the policy is true desired
###   state: create = POST, update = PUT (full replacement — the only update verb
###   assignmentPolicies support, see accesspackageassignmentpolicy-update), delete =
###   DELETE, all tracked in Terraform state and visible at plan time. The azuread
###   provider still lacks automaticRequestSettings support
###   (https://github.com/hashicorp/terraform-provider-azuread/issues/1449), which is why
###   we manage this resource directly against Microsoft Graph.
###
###   MIGRATION NOTE: a package whose policy was previously created by the old
###   null_resource path exists in Entra but not in this resource's state. Import it
###   before the first apply, otherwise the create POST makes a duplicate:
###     terraform import '<module path>.msgraph_resource.auto-assignment-policies["<key>"]' \
###       /identityGovernance/entitlementManagement/assignmentPolicies/<policyId>
####################################################################################################
resource "msgraph_resource" "auto-assignment-policies" {
  for_each = { for ap in local.access-packages : ap.key => ap if ap.auto_assignment_policy != null }

  url           = "/identityGovernance/entitlementManagement/assignmentPolicies"
  api_version   = "v1.0"
  update_method = "PUT"

  body = {
    displayName        = "${each.value.display_name}-auto-assignment-policy"
    description        = each.value.description
    allowedTargetScope = "specificDirectoryUsers"
    specificAllowedTargets = [{
      "@odata.type"  = "#microsoft.graph.attributeRuleMembers"
      description    = "Attribute rule for auto-assignment"
      membershipRule = each.value.auto_assignment_policy.filter
    }]
    automaticRequestSettings = {
      requestAccessForAllowedTargets             = true
      removeAccessWhenTargetLeavesAllowedTargets = each.value.auto_assignment_policy.remove_when_target_leaves
      gracePeriodBeforeAccessRemoval             = each.value.auto_assignment_policy.grace_period_before_removal
    }
    accessPackage = {
      id = azuread_access_package.access-packages[each.key].id
    }
  }

  # Graph echoes back server-managed fields (createdDateTime, etc.) and defaults for the
  # request-based settings that don't apply to an auto-assignment policy. Suppress diffs for
  # properties we don't set so they don't surface as perpetual drift.
  ignore_missing_property = true

  response_export_values = {
    id              = "id"
    membership_rule = "specificAllowedTargets[0].membershipRule"
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    azuread_access_package.access-packages,
    null_resource.catalog-associations,
    azuread_access_package_resource_package_association.resource-access-package-associations
  ]
}

####################################################################################################
###   Drain active assignments before package deletion
###   Required because the Graph API rejects DELETE on a package that still has Delivered assignments.
###   Runs as a destroy-time provisioner so it always executes before the azuread_access_package destroy.
###   Token acquisition: uses ARM_TENANT_ID / ARM_CLIENT_ID / ARM_CLIENT_SECRET when set (SP application token with full permissions), falls back to `az` CLI.
####################################################################################################
resource "terraform_data" "force-remove-assignments" {
  for_each = { for ap in local.access-packages : ap.key => ap }

  input = azuread_access_package.access-packages[each.key].id

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      PACKAGE_ID="${self.input}"
      GRAPH_URL="https://graph.microsoft.com/v1.0"
      ODATA_FILTER='$filter'

      TOKEN=""
      if [ -n "$ARM_TENANT_ID" ] && [ -n "$ARM_CLIENT_ID" ] && [ -n "$ARM_CLIENT_SECRET" ]; then
        TOKEN=$(curl --silent --fail --request POST \
          "https://login.microsoftonline.com/$ARM_TENANT_ID/oauth2/v2.0/token" \
          --header "Content-Type: application/x-www-form-urlencoded" \
          --data "client_id=$ARM_CLIENT_ID&client_secret=$ARM_CLIENT_SECRET&scope=https://graph.microsoft.com/.default&grant_type=client_credentials" \
          | jq --raw-output '.access_token')
      fi
      if [ -z "$TOKEN" ] && command -v az >/dev/null 2>&1; then
        TOKEN=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken --output tsv 2>/dev/null || true)
      fi
      if [ -z "$TOKEN" ]; then
        echo "ERROR: Could not obtain a Graph API token. Set ARM_TENANT_ID, ARM_CLIENT_ID, and ARM_CLIENT_SECRET, or run 'az login'."
        exit 1
      fi

      # Step 1: disable auto-assignment policies before sweeping assignments.
      # Entra blocks DELETE on a policy that has active assignments, so we PATCH to
      # disable auto-assignment first. Without this, the policy re-grants access as
      # fast as assignments are removed, leaving the package in a state that blocks
      # deletion. Terraform then deletes the now-disabled policy as a resource.
      # Derive policy IDs from active assignments' assignmentPolicyId field — the
      # assignmentPolicies filter endpoint can return stale cached IDs that 404 on PATCH.
      # Active assignments always reference the real live policy. PATCH 404s and other
      # 4xx responses are handled gracefully below.
      AUTO_POLICIES=$(curl --silent --fail \
        --header "Authorization: Bearer $TOKEN" \
        --get \
        --data-urlencode "$ODATA_FILTER=accessPackage/id eq '$PACKAGE_ID'" \
        "$GRAPH_URL/identityGovernance/entitlementManagement/assignments" \
        | jq --raw-output '[.value[] | select((.state | ascii_downcase) != "expired" and (.state | ascii_downcase) != "canceled") | .assignmentPolicyId] | unique[] // empty')

      for POLICY_ID in $AUTO_POLICIES; do
        echo "Disabling auto-assignment policy $POLICY_ID..."
        HTTP_STATUS=$(curl --silent --write-out "%%{http_code}" --output /dev/null \
          --request PATCH \
          --header "Authorization: Bearer $TOKEN" \
          --header "Content-Type: application/json" \
          --data '{"automaticRequestSettings":{"requestAccessForAllowedTargets":false},"accessPackageNotificationSettings":{"@odata.type":"#microsoft.graph.accessPackageNotificationSettings","isAssignmentNotificationDisabled":true}}' \
          "$GRAPH_URL/identityGovernance/entitlementManagement/assignmentPolicies/$POLICY_ID")
        if [ "$HTTP_STATUS" = "404" ]; then
          echo "  Policy $POLICY_ID not found (already deleted) - skipping"
        elif [ "$HTTP_STATUS" -ge 400 ]; then
          echo "  Warning: PATCH returned HTTP $HTTP_STATUS for policy $POLICY_ID - continuing"
        fi
      done

      if [ -n "$AUTO_POLICIES" ]; then
        echo "Waiting 15s for policy disable to propagate before sweeping assignments..."
        sleep 15
      fi

      # Step 2: remove all non-expired assignments. Query by accessPackage/id only and
      # filter out Expired/Canceled client-side - 'ne' on state is not supported by this
      # endpoint and silently returns empty results. Use ascii_downcase for case-insensitive
      # comparison - the Graph API returns lowercase states ("delivered", "expired").
      ASSIGNMENTS=$(curl --silent --fail \
        --header "Authorization: Bearer $TOKEN" \
        --get \
        --data-urlencode "$ODATA_FILTER=accessPackage/id eq '$PACKAGE_ID'" \
        "$GRAPH_URL/identityGovernance/entitlementManagement/assignments" \
        | jq --raw-output '.value[] | select((.state | ascii_downcase) != "expired" and (.state | ascii_downcase) != "canceled") | .id')

      if [ -z "$ASSIGNMENTS" ]; then
        echo "No active assignments for package $PACKAGE_ID - proceeding."
        exit 0
      fi

      echo "Submitting AdminRemove requests for package $PACKAGE_ID..."
      for ASSIGNMENT_ID in $ASSIGNMENTS; do
        echo "  Removing assignment $ASSIGNMENT_ID"
        HTTP_STATUS=$(curl --silent --write-out "%%{http_code}" --output /dev/null \
          --request POST \
          --header "Authorization: Bearer $TOKEN" \
          --header "Content-Type: application/json" \
          --data "{\"requestType\":\"AdminRemove\",\"assignment\":{\"id\":\"$ASSIGNMENT_ID\"}}" \
          "$GRAPH_URL/identityGovernance/entitlementManagement/assignmentRequests")
        if [ "$HTTP_STATUS" -ge 400 ]; then
          echo "  Warning: AdminRemove returned HTTP $HTTP_STATUS for assignment $ASSIGNMENT_ID - skipping"
        fi
      done

      echo "Waiting for assignments to be removed (up to 5 min)..."
      ATTEMPTS=0
      while [ $ATTEMPTS -lt 30 ]; do
        REMAINING=$(curl --silent --fail \
          --header "Authorization: Bearer $TOKEN" \
          --get \
          --data-urlencode "$ODATA_FILTER=accessPackage/id eq '$PACKAGE_ID'" \
          "$GRAPH_URL/identityGovernance/entitlementManagement/assignments" \
          | jq '[.value[] | select((.state | ascii_downcase) != "expired" and (.state | ascii_downcase) != "canceled")] | length')
        if [ "$REMAINING" -eq 0 ]; then
          echo "All assignments removed - ready to delete package."
          exit 0
        fi
        echo "  $REMAINING assignment(s) still active, retrying in 10s..."
        sleep 10
        ATTEMPTS=$((ATTEMPTS + 1))
      done
      echo "WARNING: Timed out after 5 minutes. Proceeding with package deletion anyway."
    EOT
  }

  depends_on = [
    azuread_access_package.access-packages,
    msgraph_resource.auto-assignment-policies,
    azuread_access_package_assignment_policy.assignment_policies,
  ]
}

###   Migrate existing azuread_access_package_resource_catalog_association state to
###   null_resource.catalog-associations without destroying the Azure resources.
removed {
  from = azuread_access_package_resource_catalog_association.resource-catalog-associations
  lifecycle {
    destroy = false
  }
}

###   Validation - Teams groups used as resources must have Static membership.
###   Dynamic groups do not expose an Owner role in the entitlement catalog.
###   Remove the group from teams_resources and use auto_assignment_policy with
###   the group's dynamic membership rule as the filter instead.
###################################################################
resource "terraform_data" "validate_teams_not_dynamic" {
  lifecycle {
    precondition {
      condition     = length(local._dynamic_teams_groups) == 0
      error_message = "Teams groups with Dynamic membership cannot be used as access package resources — dynamic groups do not expose an Owner role in the entitlement catalog. Remove each group from teams_resources and use auto_assignment_policy with its dynamic rule as the filter instead:\n${join("\n", [for name, rule in local._dynamic_teams_groups : "  '${name}': ${rule}"])}"
    }
  }
}

###   Identity Governance - Resource Catalog Associations (AadGroup/AadApplication)
###   Uses null_resource + local-exec to idempotently onboard AadGroup/AadApplication
###   resources to the catalog. Checks via Graph API before POSTing - skips if already
###   onboarded. Mirrors the SharePoint pattern to handle resources that exist in Azure
###   but not in Terraform state without erroring.
###################################################################
resource "null_resource" "catalog-associations" {
  for_each = { for resource in local.resource-catalog-associations-filtered : resource.catalog_resource_association_key => resource }

  triggers = {
    catalog_id    = local.catalog_ids[each.value.catalog_key]
    origin_id     = each.value.resource_origin_id
    origin_system = each.value.resource_origin_system
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      token=$(curl -sf -X POST \
        "https://login.microsoftonline.com/$ARM_TENANT_ID/oauth2/v2.0/token" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=$ARM_CLIENT_ID" \
        --data-urlencode "client_secret=$ARM_CLIENT_SECRET" \
        --data-urlencode "scope=https://graph.microsoft.com/.default" \
        | jq -r '.access_token')

      source "${path.module}/scripts/graph_get.sh"

      poll_available() {
        for i in $(seq 1 36); do
          sleep 10
          available=$(graph_get \
            "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/${self.triggers.catalog_id}/resources" \
            --data-urlencode "\$filter=originId eq '${self.triggers.origin_id}'" \
            | jq '.value | length')
          if [ "$${available:-0}" -gt 0 ]; then
            echo "[+] Resource available in catalog after $((i * 10))s"
            return 0
          fi
          if [ "$i" -eq 36 ]; then
            echo "Error: resource still not in available state after 360s"
            return 1
          fi
        done
      }

      count=$(graph_get \
        "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/${self.triggers.catalog_id}/resources" \
        --data-urlencode "\$filter=originId eq '${self.triggers.origin_id}'" \
        | jq '.value | length')

      if [ "$count" -eq 0 ]; then
        body=$(jq -n \
          --arg oid "${self.triggers.origin_id}" \
          --arg osys "${self.triggers.origin_system}" \
          --arg cid "${self.triggers.catalog_id}" \
          '{"requestType":"AdminAdd","justification":"","resource":{"originId":$oid,"originSystem":$osys},"catalog":{"id":$cid}}')
        HTTP_STATUS="429"
        post_attempt=0
        post_delay=15
        while [ "$HTTP_STATUS" = "429" ] && [ $post_attempt -lt 5 ]; do
          HTTP_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/resourceRequests" \
            -d "$body")
          if [ "$HTTP_STATUS" = "429" ]; then
            post_attempt=$((post_attempt + 1))
            echo "[!] POST rate limited (429), retry $post_attempt/5 in $${post_delay}s..."
            sleep $post_delay
            post_delay=$((post_delay * 2))
          fi
        done
        if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
          echo "[+] Associated: ${self.triggers.origin_id} - waiting for catalog propagation..."
          poll_available
        else
          recheck=$(graph_get \
            "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/${self.triggers.catalog_id}/resources" \
            --data-urlencode "\$filter=originId eq '${self.triggers.origin_id}'" \
            | jq '.value | length')
          if [ "$${recheck:-0}" -gt 0 ]; then
            echo "[=] Already in catalog: ${self.triggers.origin_id}"
          else
            echo "[!] POST returned HTTP $HTTP_STATUS and resource still not in catalog" >&2
            exit 1
          fi
        fi
      else
        echo "[=] Already in catalog: ${self.triggers.origin_id}"
      fi
    EOT
  }

  depends_on = [azuread_access_package_catalog.entitlement-catalogs]
}

###   Identity Governance - Resource Access Package Associations
###################################################################
resource "azuread_access_package_resource_package_association" "resource-access-package-associations" {
  for_each = { for resource in local.resources : resource.access_package_resource_association_key => resource if resource.resource_origin_system != "AadApplication" && resource.resource_origin_system != "SharePointOnline" }

  catalog_resource_association_id = "${local.catalog_ids[each.value.catalog_key]}/${each.value.resource_origin_id}"
  access_package_id               = azuread_access_package.access-packages[each.value.access_package_key].id
  access_type                     = each.value.access_type

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    azuread_access_package.access-packages,
    null_resource.catalog-associations
  ]
}

data "msgraph_resource" "resource_access_package_catalog_resources" {
  for_each = { for resource in local.resources : resource.access_package_resource_association_key => resource if resource.resource_origin_system == "AadApplication" }
  url      = "/identityGovernance/entitlementManagement/catalogs/${local.catalog_ids[each.value.catalog_key]}/resources"
  query_parameters = {
    "$filter" = ["(originId eq '${each.value.resource_origin_id}')"]
    "$expand" = ["scopes"]
  }
  response_export_values = {
    all      = "@"
    id       = "value[0].id"
    scope_id = "value[0].scopes[0].id"
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    azuread_access_package.access-packages,
    null_resource.catalog-associations
  ]
}

data "msgraph_resource" "resource_access_package_catalog_resource_roles" {
  for_each = { for resource in local.resources : resource.access_package_resource_association_key => resource if resource.resource_origin_system == "AadApplication" }
  url      = "/identityGovernance/entitlementManagement/catalogs/${local.catalog_ids[each.value.catalog_key]}/resourceRoles"
  query_parameters = {
    "$filter" = ["(originSystem eq 'AadApplication' and resource/id eq '${data.msgraph_resource.resource_access_package_catalog_resources[each.key].output.id}')"]
    "$expand" = ["resource"]
  }
  response_export_values = {
    all          = "@"
    originid     = "value[0].originId"
    display_name = "value[0].displayName"
    description  = "value[0].description"
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    azuread_access_package.access-packages,
    null_resource.catalog-associations
  ]
}

###   Identity Governance - Resource Catalog Associations for SharePointOnline
###   Uses null_resource + local-exec to idempotently onboard SP resources to the catalog.
###   Checks via Graph API before POSTing - skips if already onboarded.
###   ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID must be set in the environment
###   (the azuread provider sets these automatically from its own authentication config).
###################################################################
resource "null_resource" "sharepoint-catalog-associations" {
  for_each = { for resource in local.sharepoint-catalog-associations-filtered : resource.catalog_resource_association_key => resource }

  triggers = {
    catalog_id = local.catalog_ids[each.value.catalog_key]
    origin_id  = each.value.resource_origin_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      token=$(curl -sf -X POST \
        "https://login.microsoftonline.com/$ARM_TENANT_ID/oauth2/v2.0/token" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=$ARM_CLIENT_ID" \
        --data-urlencode "client_secret=$ARM_CLIENT_SECRET" \
        --data-urlencode "scope=https://graph.microsoft.com/.default" \
        | jq -r '.access_token')

      source "${path.module}/scripts/graph_get.sh"

      count=$(graph_get \
        "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/${self.triggers.catalog_id}/resources" \
        | jq --arg oid "${self.triggers.origin_id}" '[.value[] | select(.originId == $oid)] | length')

      if [ "$count" -eq 0 ]; then
        body=$(jq -n \
          --arg oid "${self.triggers.origin_id}" \
          --arg cid "${self.triggers.catalog_id}" \
          '{"requestType":"AdminAdd","justification":"","resource":{"originId":$oid,"originSystem":"SharePointOnline"},"catalog":{"id":$cid}}')
        HTTP_STATUS="429"
        post_attempt=0
        post_delay=15
        while [ "$HTTP_STATUS" = "429" ] && [ $post_attempt -lt 5 ]; do
          HTTP_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/resourceRequests" \
            -d "$body")
          if [ "$HTTP_STATUS" = "429" ]; then
            post_attempt=$((post_attempt + 1))
            echo "[!] POST rate limited (429), retry $post_attempt/5 in $${post_delay}s..."
            sleep $post_delay
            post_delay=$((post_delay * 2))
          fi
        done
        if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
          echo "[+] Onboarded: ${self.triggers.origin_id}"
        else
          recheck=$(graph_get \
            "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/${self.triggers.catalog_id}/resources" \
            | jq --arg oid "${self.triggers.origin_id}" '[.value[] | select(.originId == $oid)] | length')
          if [ "$${recheck:-0}" -gt 0 ]; then
            echo "[=] Already in catalog: ${self.triggers.origin_id}"
          else
            echo "[!] POST returned HTTP $HTTP_STATUS and resource still not in catalog" >&2
            exit 1
          fi
        fi
      else
        echo "[=] Already in catalog: ${self.triggers.origin_id}"
      fi
    EOT
  }

  depends_on = [azuread_access_package_catalog.entitlement-catalogs]
}

data "msgraph_resource" "sharepoint_catalog_resources" {
  for_each = { for resource in local.resources : resource.access_package_resource_association_key => resource if resource.resource_origin_system == "SharePointOnline" }
  url      = "/identityGovernance/entitlementManagement/catalogs/${local.catalog_ids[each.value.catalog_key]}/resources"
  query_parameters = {
    "$filter" = ["(originId eq '${each.value.resource_origin_id}')"]
    "$expand" = ["scopes"]
  }
  response_export_values = {
    all      = "@"
    id       = "value[0].id"
    scope_id = "value[0].scopes[0].id"
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    null_resource.sharepoint-catalog-associations
  ]
}

data "msgraph_resource" "sharepoint_catalog_resource_roles" {
  for_each = { for resource in local.resources : resource.access_package_resource_association_key => resource if resource.resource_origin_system == "SharePointOnline" }
  url      = "/identityGovernance/entitlementManagement/catalogs/${local.catalog_ids[each.value.catalog_key]}/resourceRoles"
  query_parameters = {
    "$filter" = ["(originSystem eq 'SharePointOnline' and resource/id eq '${data.msgraph_resource.sharepoint_catalog_resources[each.key].output.id}')"]
    "$expand" = ["resource"]
  }
  response_export_values = {
    all = "@"
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    null_resource.sharepoint-catalog-associations,
    data.msgraph_resource.sharepoint_catalog_resources
  ]
}

###   Identity Governance - Resource Access Package Associations for SharePointOnline
###   due to https://github.com/hashicorp/terraform-provider-azuread/issues/1637
###################################################################
resource "msgraph_resource_action" "sharepoint-access-package-associations" {
  for_each     = { for resource in local.resources : resource.access_package_resource_association_key => resource if resource.resource_origin_system == "SharePointOnline" }
  resource_url = "/identityGovernance/entitlementManagement/accessPackages/${azuread_access_package.access-packages[each.value.access_package_key].id}/resourceRoleScopes"
  method       = "POST"

  body = {
    role = {
      displayName  = tostring(local._sp_selected_role[each.key]["displayName"])
      originSystem = "SharePointOnline"
      originId     = tostring(local._sp_selected_role[each.key]["originId"])
      resource = {
        id = data.msgraph_resource.sharepoint_catalog_resources[each.key].output.id
      }
    }
    scope = {
      displayName  = "Root"
      description  = "Root Scope"
      originId     = each.value.resource_origin_id
      originSystem = "SharePointOnline"
      isRootScope  = true
    }
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    azuread_access_package.access-packages,
    null_resource.sharepoint-catalog-associations,
    data.msgraph_resource.sharepoint_catalog_resources,
    data.msgraph_resource.sharepoint_catalog_resource_roles
  ]
}

###   Identity Governance - Resource Access Package Associations for AadApplication due to https://github.com/hashicorp/terraform-provider-azuread/issues/1066
###################################################################
resource "msgraph_resource_action" "resource-access-package-associations" {
  for_each     = { for resource in local.resources : resource.access_package_resource_association_key => resource if resource.resource_origin_system == "AadApplication" }
  resource_url = "/identityGovernance/entitlementManagement/accessPackages/${azuread_access_package.access-packages[each.value.access_package_key].id}/resourceRoleScopes"
  method       = "POST"

  body = {
    role = {
      id           = each.value.access_type
      displayName  = data.msgraph_resource.resource_access_package_catalog_resource_roles[each.key].output.display_name
      description  = data.msgraph_resource.resource_access_package_catalog_resource_roles[each.key].output.description
      originSystem = each.value.resource_origin_system
      originId     = data.msgraph_resource.resource_access_package_catalog_resource_roles[each.key].output.originid
      resource = {
        id           = data.msgraph_resource.resource_access_package_catalog_resources[each.key].output.id
        originId     = each.value.resource_origin_id
        originSystem = each.value.resource_origin_system
      }
    }
    scope = {
      id           = data.msgraph_resource.resource_access_package_catalog_resources[each.key].output.scope_id
      originId     = each.value.resource_origin_id
      originSystem = each.value.resource_origin_system
      isRootScope  = true
    }
  }

  depends_on = [
    azuread_access_package_catalog.entitlement-catalogs,
    azuread_access_package.access-packages,
    null_resource.catalog-associations
  ]
}
