# ==============================================================================
# Pulse Telco — Standalone End-State Reference Production Agent (Terraform IaC)
# ==============================================================================
# Deploys the complete Pulse Telco solution into one (possibly empty) project:
#   BigQuery domains + sample data + Knowledge Catalog aspects, persona service accounts with
#   dataset ACLs, the IAM Context MCP server and NOC A2A agent on Cloud Run (+ Agent Registry),
#   Model Armor templates, and the `pulse-concierge-prod` Chat + Live Voice agent on Agent Runtime.
#   The optional egress Agent Gateway lives in gateway.tf (enable_agent_gateway).
# EU-wide multi-region endpoints first (Gemini `eu`, BigQuery `EU`, Knowledge Catalog `eu`),
# then one region (var.region) for regional services.
# ==============================================================================

# Read after the APIs are enabled: an empty project has cloudresourcemanager.googleapis.com off.
data "google_project" "current" {
  project_id = var.project_id
  depends_on = [google_project_service.apis]
}

locals {
  project_number       = data.google_project.current.number
  model_armor_location = coalesce(var.model_armor_location, var.region)
  kc_location          = lower(var.bq_location)
  repo_root            = abspath("${path.module}/../..")
  agent_dir            = "${path.module}/../pulse-concierge-prod"

  iam_mcp_url = "https://pulse-iam-context-mcp-${local.project_number}.${var.region}.run.app/mcp"
  noc_host    = "pulse-network-ops-agent-${local.project_number}.${var.region}.run.app"
  noc_url     = "https://${local.noc_host}"

  required_apis = toset([
    "aiplatform.googleapis.com",
    "agentregistry.googleapis.com",
    "apphub.googleapis.com",
    "apptopology.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudapiregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "dataplex.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "modelarmor.googleapis.com",
    "monitoring.googleapis.com",
    "observability.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "telemetry.googleapis.com",
  ])

  datasets = {
    telco_crm     = "Pulse Telco CRM domain: subscribers, segments, ML churn risk scores, and active mobile/fiber tariff subscriptions."
    telco_billing = "Pulse Telco Billing & Revenue Assurance domain: monthly EUR invoices, delinquency, payment transactions, and dispute notes."
    telco_network = "Pulse Telco Network Operations (NOC) domain: 5G/LTE cell towers, utilization, packet loss, and outage incidents."
  }

  # Admin (Alex) reads all three domains; Specialist (Elena) reads telco_crm only.
  personas = {
    "persona-alex-exec"  = { display = "Alex Novak (Admin - Full BI Access)", datasets = ["telco_crm", "telco_billing", "telco_network"] }
    "persona-elena-care" = { display = "Elena Kovac (Specialist - CRM Only Access)", datasets = ["telco_crm"] }
  }
  persona_dataset_access = merge([
    for p, cfg in local.personas : { for ds in cfg.datasets : "${p}/${ds}" => { persona = p, dataset = ds } }
  ]...)

  mock_sha = {
    for svc in ["telco-iam-context-mcp", "telco-network-ops-agent"] :
    svc => sha256(join("", [for f in sort(fileset("${local.repo_root}/mocks/${svc}", "{*.py,Dockerfile,requirements.txt}")) : filesha256("${local.repo_root}/mocks/${svc}/${f}")]))
  }
  agent_sha = sha256(join("", concat(
    [for f in sort(fileset("${local.agent_dir}/app", "**")) : filesha256("${local.agent_dir}/app/${f}") if !strcontains(f, "__pycache__")],
    [for f in ["pyproject.toml", "uv.lock", "Dockerfile"] : filesha256("${local.agent_dir}/${f}")],
  )))
}

resource "google_project_service" "apis" {
  for_each           = local.required_apis
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# The default compute service account appears a little after compute.googleapis.com is enabled.
resource "null_resource" "wait_for_apis" {
  triggers   = { project_id = var.project_id }
  depends_on = [google_project_service.apis]

  provisioner "local-exec" {
    command = "sleep 60"
  }
}

# Cloud Run source builds and the NOC agent's Gemini calls use the default compute service account.
resource "google_project_iam_member" "compute_sa_roles" {
  for_each   = toset(["roles/cloudbuild.builds.builder", "roles/aiplatform.user", "roles/logging.logWriter"])
  project    = var.project_id
  role       = each.value
  member     = "serviceAccount:${local.project_number}-compute@developer.gserviceaccount.com"
  depends_on = [null_resource.wait_for_apis]
}

# --- 1. BigQuery domains (EU) + sample data + Knowledge Catalog ---------------------------------
resource "google_bigquery_dataset" "domains" {
  for_each                   = local.datasets
  project                    = var.project_id
  dataset_id                 = each.key
  location                   = var.bq_location
  description                = each.value
  delete_contents_on_destroy = true
  depends_on                 = [google_project_service.apis]
}

resource "null_resource" "seed_data" {
  triggers = {
    data_sha   = sha256(join("", [for f in sort(fileset("${local.repo_root}/data", "*.json")) : filesha256("${local.repo_root}/data/${f}")]))
    script_sha = filesha256("${path.module}/scripts/seed_data.py")
    project_id = var.project_id
  }

  provisioner "local-exec" {
    working_dir = local.repo_root
    command     = "uv run python3 reference-production-agent/terraform/scripts/seed_data.py ${var.project_id} ${local.project_number} ${var.bq_location} ${local.kc_location}"
  }

  depends_on = [google_bigquery_dataset.domains]
}

# --- 2. Persona identities with dataset-level BigQuery ACLs -------------------------------------
resource "google_service_account" "personas" {
  for_each     = local.personas
  project      = var.project_id
  account_id   = each.key
  display_name = each.value.display
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "persona_job_user" {
  for_each = local.personas
  project  = var.project_id
  role     = "roles/bigquery.jobUser"
  member   = google_service_account.personas[each.key].member
}

resource "google_bigquery_dataset_iam_member" "persona_readers" {
  for_each   = local.persona_dataset_access
  project    = var.project_id
  dataset_id = google_bigquery_dataset.domains[each.value.dataset].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.personas[each.value.persona].member
}

# --- 3. Model Armor templates ---------------------------------------------------------------------
resource "google_model_armor_template" "guard" {
  for_each    = toset(["input", "output"])
  project     = var.project_id
  location    = local.model_armor_location
  template_id = "pulse-prod-guard-${each.key}"

  filter_config {
    rai_settings {
      dynamic "rai_filters" {
        for_each = ["HATE_SPEECH", "DANGEROUS", "HARASSMENT", "SEXUALLY_EXPLICIT"]
        content {
          filter_type      = rai_filters.value
          confidence_level = "MEDIUM_AND_ABOVE"
        }
      }
    }
    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
    # Prompt injection / jailbreak screening applies to what flows *into* the model.
    dynamic "pi_and_jailbreak_filter_settings" {
      for_each = each.key == "input" ? [1] : []
      content {
        filter_enforcement = "ENABLED"
        confidence_level   = "MEDIUM_AND_ABOVE"
      }
    }
  }

  depends_on = [google_project_service.apis]
}

# --- 4. Remote tools on Cloud Run: IAM Context MCP server + NOC A2A agent ------------------------
resource "null_resource" "iam_context_mcp" {
  triggers = {
    source_sha = local.mock_sha["telco-iam-context-mcp"]
    project_id = var.project_id
    region     = var.region
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/deploy_cloud_run.sh pulse-iam-context-mcp ${local.repo_root}/mocks/telco-iam-context-mcp ${var.project_id} ${var.region} 512Mi"
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "gcloud run services delete pulse-iam-context-mcp --region=${self.triggers.region} --project=${self.triggers.project_id} --quiet"
  }

  depends_on = [google_project_iam_member.compute_sa_roles]
}

resource "null_resource" "network_ops_agent" {
  triggers = {
    source_sha     = local.mock_sha["telco-network-ops-agent"]
    project_id     = var.project_id
    region         = var.region
    model_location = var.model_location
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/deploy_cloud_run.sh pulse-network-ops-agent ${local.repo_root}/mocks/telco-network-ops-agent ${var.project_id} ${var.region} 1Gi GOOGLE_CLOUD_PROJECT=${var.project_id},GOOGLE_CLOUD_LOCATION=${var.model_location},GOOGLE_GENAI_USE_VERTEXAI=true,A2A_HOST=${local.noc_host}"
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "gcloud run services delete pulse-network-ops-agent --region=${self.triggers.region} --project=${self.triggers.project_id} --quiet"
  }

  depends_on = [google_project_iam_member.compute_sa_roles]
}

# Agent Registry: MCP server (tool spec), NOC agent (card) and the Google API endpoints the agent calls.
resource "null_resource" "agent_registry_entries" {
  triggers = {
    script_sha  = filesha256("${path.module}/scripts/ensure_registry.sh")
    project_id  = var.project_id
    region      = var.region
    iam_mcp_sha = local.mock_sha["telco-iam-context-mcp"]
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/ensure_registry.sh ${var.project_id} ${var.region} ${var.model_location} ${local.model_armor_location} ${local.iam_mcp_url} ${local.noc_url}"
  }

  depends_on = [null_resource.iam_context_mcp, null_resource.network_ops_agent]
}

# --- 5. Telemetry bucket ----------------------------------------------------------------------------
resource "google_storage_bucket" "prod_telemetry_bucket" {
  name                        = "${var.project_id}-${var.agent_name}-telemetry"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.apis]
}

# --- 6. Package, deploy & verify `pulse-concierge-prod` on Agent Runtime ----------------------------
# Runs on any change to the agent package or its configuration. The gateway key is only added when
# used, so toggling enable_agent_gateway redeploys the agent (bound / unbound).
resource "null_resource" "deploy_and_verify_prod_agent" {
  count = var.deploy_agent_runtime ? 1 : 0

  triggers = merge(
    {
      agent_sha            = local.agent_sha
      script_sha           = filesha256("${path.module}/scripts/deploy_and_verify.py")
      project_id           = var.project_id
      region               = var.region
      model_location       = var.model_location
      live_location        = var.live_location
      model_armor_location = local.model_armor_location
    },
    var.enable_agent_gateway ? { agent_gateway = local.gateway_id } : {},
  )

  provisioner "local-exec" {
    working_dir = local.repo_root
    command = join(" ", compact([
      "uv run python3 reference-production-agent/terraform/scripts/deploy_and_verify.py",
      "--project-id ${var.project_id} --region ${var.region}",
      "--model-location ${var.model_location} --live-location ${var.live_location} --bq-location ${var.bq_location}",
      "--ma-input-template ${google_model_armor_template.guard["input"].id}",
      "--ma-output-template ${google_model_armor_template.guard["output"].id}",
      "--iam-mcp-url ${local.iam_mcp_url} --network-ops-agent-url ${local.noc_url}",
      var.enable_agent_gateway ? "--agent-gateway ${local.gateway_id}" : "",
    ]))
  }

  depends_on = [
    null_resource.seed_data,
    google_bigquery_dataset_iam_member.persona_readers,
    google_project_iam_member.persona_job_user,
    null_resource.agent_registry_entries,
    google_storage_bucket.prod_telemetry_bucket,
    google_network_security_authz_policy.iap,
  ]
}
