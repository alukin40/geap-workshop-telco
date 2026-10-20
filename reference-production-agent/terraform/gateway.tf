# ==============================================================================
# Optional egress Agent Gateway for pulse-concierge-prod (enable_agent_gateway = true)
# ==============================================================================
# Agent Runtime accepts ONE egress (AGENT_TO_ANYWHERE) gateway per project: delete any other one
# (e.g. pulse-egress-gateway from an older Lab 06) before enabling this.
# Every outbound call of the agent container (Gemini, MCP servers, A2A agents, Google APIs) goes
# through a Google-managed forward proxy that:
#   1. matches the destination against Agent Registry (default-deny by hostname),
#   2. asks IAP whether the agent's identity may reach it (IAM v3 access policy with CEL), and
#   3. optionally screens MCP / A2A payloads with Model Armor (CONTENT_AUTHZ).
# All resource names use the `pulse-prod-` prefix so they never collide with the Lab 06 resources.
# ==============================================================================

data "google_project_ancestry" "current" {
  count      = var.enable_agent_gateway ? 1 : 0
  project    = var.project_id
  depends_on = [google_project_service.apis]
}

locals {
  gateway_name = "pulse-prod-egress-gateway"
  gateway_id   = "projects/${var.project_id}/locations/${var.region}/agentGateways/${local.gateway_name}"
  registry     = "//agentregistry.googleapis.com/projects/${var.project_id}/locations/${var.region}"
  org_id       = var.enable_agent_gateway ? data.google_project_ancestry.current[0].org_id : ""


  # The access policy names this agent's own Agent Identity (SPIFFE principal). The Reasoning Engine
  # ID is only known after the first deploy; until then the policy falls back to "every Agent
  # Runtime agent in this project". On a brand-new project, apply once with
  # enable_agent_gateway = false, then switch it on.
  agent_engine_id = try(regex("^projects/${local.project_number}/locations/${var.region}/reasoningEngines/([0-9]+)$", jsondecode(file("${path.module}/../pulse-concierge-prod/deployment_metadata.json")).remote_agent_runtime_id)[0], "")
  agent_principal = (local.agent_engine_id != ""
    ? "principal://agents.global.org-${local.org_id}.system.id.goog/resources/aiplatform/projects/${local.project_number}/locations/${var.region}/reasoningEngines/${local.agent_engine_id}"
    : "principalSet://agents.global.org-${local.org_id}.system.id.goog/attribute.platformContainer/aiplatform/projects/${local.project_number}"
  )

  in_registry = "destination.is_registered == true && destination.agent_registry.location == '${var.region}'"
  egress_rules = [
    {
      description = "Registered Google API endpoints (Gemini, sessions, memory, telemetry, Model Armor, BigQuery MCP, Knowledge Catalog MCP)"
      expression  = "${local.in_registry} && destination.agent_registry.resource_type == 'ENDPOINT'"
    },
    {
      description = "Registered A2A agents (NOC desk)"
      expression  = "${local.in_registry} && destination.agent_registry.resource_type == 'AGENT'"
    },
    {
      description = "Registered MCP servers: protocol methods other than tool calls (initialize, tools/list, ...)"
      expression  = "${local.in_registry} && destination.agent_registry.resource_type == 'MCP_SERVER' && destination.agent_registry.mcp_server.method != 'tools/call'"
    },
    {
      description = "Registered MCP servers: tool calls ONLY for tools annotated readOnlyHint=true (grant_dataset_access is denied)"
      expression  = "${local.in_registry} && destination.agent_registry.resource_type == 'MCP_SERVER' && destination.agent_registry.mcp_server.method == 'tools/call' && destination.agent_registry.mcp_server.tool.annotations.read_only_hint == true"
    },
  ]

  gateway_apis = toset([
    "iap.googleapis.com",
    "networksecurity.googleapis.com",
    "networkservices.googleapis.com",
    "orgpolicy.googleapis.com",
  ])
}

resource "google_project_service" "gateway_apis" {
  for_each           = var.enable_agent_gateway ? local.gateway_apis : toset([])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- 0. Org-policy overrides (only where you are org policy admin, e.g. Argolis) ----------------
# Project-level overrides are left in place on destroy on purpose: they are shared with anything
# else in the project. Remove them manually with `gcloud org-policies reset`.
resource "null_resource" "org_policy_overrides" {
  count = var.enable_agent_gateway && var.apply_org_policy_overrides ? 1 : 0

  triggers = {
    project_id  = var.project_id
    model_armor = var.agent_gateway_model_armor
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      f=$(mktemp --suffix=.yaml)
      printf 'name: projects/%s/policies/iam.managed.disableAccessPolicyBinding\nspec:\n  rules:\n  - enforce: false\n' "${var.project_id}" > "$f"
      gcloud org-policies set-policy "$f" --quiet >/dev/null
      if [ "${var.agent_gateway_model_armor}" = "true" ]; then
        printf 'name: projects/%s/policies/iam.allowedPolicyMemberDomains\nspec:\n  rules:\n  - allowAll: true\n' "${var.project_id}" > "$f"
        gcloud org-policies set-policy "$f" --quiet >/dev/null
      fi
      rm -f "$f"
      echo "org-policy overrides set on ${var.project_id}"
    EOT
  }

  depends_on = [google_project_service.gateway_apis]
}

# --- 1. Agent Registry entries: see null_resource.agent_registry_entries in main.tf ----------------

# --- 2. The gateway itself (native) -------------------------------------------------------------
resource "google_network_services_agent_gateway" "egress" {
  count       = var.enable_agent_gateway ? 1 : 0
  project     = var.project_id
  location    = var.region
  name        = local.gateway_name
  description = "Egress Agent Gateway for pulse-concierge-prod (reference production agent)"
  registries  = [local.registry]

  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }

  depends_on = [google_project_service.gateway_apis]
}

# --- 3. IAP authorization (REQUEST_AUTHZ): who may call what --------------------------------------
resource "google_network_services_authz_extension" "iap" {
  count     = var.enable_agent_gateway ? 1 : 0
  project   = var.project_id
  location  = var.region
  name      = "pulse-prod-iap-authz-ext"
  service   = "iap.googleapis.com"
  fail_open = false
  timeout   = "1s"
  # Removing iamEnforcementMode switches IAP from audit-only to enforcing.
  metadata = merge(
    { iapPolicyVersion = "V2" },
    var.agent_gateway_enforcement == "DRY_RUN" ? { iamEnforcementMode = "DRY_RUN" } : {},
  )

  depends_on = [google_project_service.gateway_apis]
}

resource "google_network_security_authz_policy" "iap" {
  count          = var.enable_agent_gateway ? 1 : 0
  project        = var.project_id
  location       = var.region
  name           = "pulse-prod-iap-authz-policy"
  policy_profile = "REQUEST_AUTHZ"
  action         = "CUSTOM"

  target {
    resources = [google_network_services_agent_gateway.egress[0].id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.iap[0].id]
    }
  }
}

# IAM v3 access policy (Unified Access Policy) evaluated by IAP for every request of this agent.
resource "google_iam_project_access_policy" "egress" {
  count            = var.enable_agent_gateway ? 1 : 0
  project          = var.project_id
  location         = "global"
  access_policy_id = "pulse-prod-egress-policy"
  display_name     = "pulse-concierge-prod egress via Agent Gateway"

  details {
    dynamic "rules" {
      for_each = local.egress_rules
      content {
        description = rules.value.description
        effect      = "ALLOW"
        principals  = [local.agent_principal]
        operation {
          permissions = ["iap.googleapis.com/resources.egressViaIAP"]
        }
        conditions {
          service    = "iap.googleapis.com"
          expression = rules.value.expression
        }
      }
    }
  }

  depends_on = [google_project_service.gateway_apis]
}

# Binding the access policy to the project. Not native: google provider < 8.0 only supports
# principal-set targets on google_iam_projects_policy_binding. If the org enforces
# iam.managed.disableAccessPolicyBinding (default for new orgs) and apply_org_policy_overrides is
# false, the binding is skipped with a warning: the gateway still works in DRY_RUN, but ENFORCED
# then has no allow rules for the agent.
resource "null_resource" "egress_policy_binding" {
  count = var.enable_agent_gateway ? 1 : 0

  triggers = {
    project_id = var.project_id
    policy     = google_iam_project_access_policy.egress[0].name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      B=pulse-prod-egress-binding
      if gcloud iam policy-bindings describe $B --project=${var.project_id} --location=global >/dev/null 2>&1; then
        echo "policy binding $B already exists"; exit 0
      fi
      for i in $(seq 1 12); do
        out=$(gcloud iam policy-bindings create $B --project=${var.project_id} --location=global \
          --policy=projects/${var.project_id}/locations/global/accessPolicies/pulse-prod-egress-policy \
          --target-resource=//cloudresourcemanager.googleapis.com/projects/${var.project_id} 2>&1) && { echo "policy binding $B created"; exit 0; }
        if echo "$out" | grep -q disableAccessPolicyBinding && [ "${var.apply_org_policy_overrides}" != "true" ]; then
          echo "WARNING: org policy iam.managed.disableAccessPolicyBinding blocks the access-policy binding."
          echo "         Ask an org policy admin to lift it for this project (or set apply_org_policy_overrides = true)."
          echo "         The gateway keeps working in DRY_RUN; ENFORCED would deny the agent's traffic."
          exit 0
        fi
        echo "binding not accepted yet ($i/12): $(echo "$out" | tail -1 | cut -c1-120)"; sleep 20
      done
      echo "$out"; exit 1
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "gcloud iam policy-bindings delete pulse-prod-egress-binding --project=${self.triggers.project_id} --location=global --quiet"
  }

  depends_on = [null_resource.org_policy_overrides]
}

# --- 4. Model Armor on the wire (CONTENT_AUTHZ) -------------------------------------------------
# The gateway calls Model Armor with a Google-managed service account; it needs these roles.
# Granted with gcloud and not removed on destroy: the service account is shared by every gateway
# in the project (Lab 06 uses the same one).
resource "null_resource" "gateway_sa_model_armor_roles" {
  count = var.enable_agent_gateway && var.agent_gateway_model_armor ? 1 : 0

  triggers = {
    gateway_sa = google_network_services_agent_gateway.egress[0].agent_gateway_card[0].service_extensions_service_account
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      for role in roles/modelarmor.calloutUser roles/serviceusage.serviceUsageConsumer roles/modelarmor.user; do
        for i in $(seq 1 10); do
          gcloud projects add-iam-policy-binding ${var.project_id} --member=serviceAccount:${self.triggers.gateway_sa} \
            --role=$role --condition=None --quiet >/dev/null 2>&1 && break
          [ $i -eq 10 ] && { echo "could not grant $role to ${self.triggers.gateway_sa} (iam.allowedPolicyMemberDomains?)"; exit 1; }
          echo "waiting to grant $role ($i/10)"; sleep 15
        done
      done
      echo "Model Armor roles granted to ${self.triggers.gateway_sa}"
    EOT
  }

  depends_on = [null_resource.org_policy_overrides]
}

resource "google_network_services_authz_extension" "model_armor" {
  count     = var.enable_agent_gateway && var.agent_gateway_model_armor ? 1 : 0
  project   = var.project_id
  location  = var.region
  name      = "pulse-prod-ma-content-ext"
  service   = "modelarmor.${local.model_armor_location}.rep.googleapis.com"
  fail_open = false
  timeout   = "1s"
  # From the gateway's viewpoint the agent's outbound request is the agent's *output* and the tool's
  # response is new *input* for the LLM, hence the swapped templates.
  metadata = {
    model_armor_settings = jsonencode([{
      request_template_id  = google_model_armor_template.guard["output"].id
      response_template_id = google_model_armor_template.guard["input"].id
    }])
  }

  depends_on = [null_resource.gateway_sa_model_armor_roles]
}

resource "google_network_security_authz_policy" "model_armor" {
  count          = var.enable_agent_gateway && var.agent_gateway_model_armor ? 1 : 0
  project        = var.project_id
  location       = var.region
  name           = "pulse-prod-ma-content-policy"
  policy_profile = "CONTENT_AUTHZ"
  action         = "CUSTOM"

  target {
    resources = [google_network_services_agent_gateway.egress[0].id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.model_armor[0].id]
    }
  }

  # Screen JSON / text payloads of MCP servers and A2A agents. *.googleapis.com (Gemini, BigQuery
  # and Knowledge Catalog MCP) is excluded: those responses are screened by the in-process plugin.
  http_rules {
    to {
      operations {
        paths {
          prefix = "/"
        }
      }
    }
    when = "(request.headers['content-type'] == 'application/json' || request.headers['content-type'].startsWith('text/')) && !request.host.endsWith('googleapis.com')"
  }

  depends_on = [google_network_security_authz_policy.iap]
}
