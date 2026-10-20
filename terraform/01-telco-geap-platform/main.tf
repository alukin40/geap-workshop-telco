data "google_project" "current" {
  project_id = var.project_id
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Google Cloud APIs
# ─────────────────────────────────────────────────────────────────────────────
locals {
  platform_apis = toset([
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "bigquery.googleapis.com",
    "dataplex.googleapis.com",
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "agentregistry.googleapis.com",
    "discoveryengine.googleapis.com",
    "run.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    "telemetry.googleapis.com",
    "observability.googleapis.com",
    "apphub.googleapis.com",
    "apptopology.googleapis.com",
    "cloudapiregistry.googleapis.com",
    "modelarmor.googleapis.com",
    "dlp.googleapis.com",
    "networkservices.googleapis.com",
    "networksecurity.googleapis.com",
    "secretmanager.googleapis.com",
  ])
}

resource "google_project_service" "platform_apis" {
  for_each           = local.platform_apis
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Service Accounts & Least-Privilege IAM
# ─────────────────────────────────────────────────────────────────────────────
resource "google_service_account" "pulse_concierge" {
  project      = var.project_id
  account_id   = "${var.agent_name}-sa"
  display_name = "Pulse Telco GEAP Orchestrator & Sub-Agents SA"
  description  = "Dedicated identity for the Pulse Telco multi-agent orchestrator on GEAP Agent Runtime"
  depends_on   = [google_project_service.platform_apis]
}

resource "google_service_account" "iam_mcp" {
  project      = var.project_id
  account_id   = "pulse-iam-mcp-sa"
  display_name = "Pulse Telco IAM & User Context MCP Server SA"
  description  = "Identity for the Cloud Run IAM & User Context MCP server"
  depends_on   = [google_project_service.platform_apis]
}

resource "google_service_account" "network_ops_agent" {
  project      = var.project_id
  account_id   = "pulse-network-ops-sa"
  display_name = "Pulse Telco Network Ops A2A Agent SA"
  description  = "Identity for the remote A2A Network Operations specialist agent on Cloud Run"
  depends_on   = [google_project_service.platform_apis]
}

resource "google_project_iam_member" "concierge_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/bigquery.dataViewer",
    "roles/bigquery.jobUser",
    "roles/dataplex.catalogViewer",
    "roles/modelarmor.user",
    "roles/cloudtrace.agent",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.pulse_concierge.email}"
}

resource "google_project_iam_member" "network_ops_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/bigquery.dataViewer",
    "roles/bigquery.jobUser",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.network_ops_agent.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Multi-Domain BigQuery Datasets & Tables (EU Data Residency)
# ─────────────────────────────────────────────────────────────────────────────
resource "google_bigquery_dataset" "telco_crm" {
  project                    = var.project_id
  dataset_id                 = var.dataset_crm
  friendly_name              = "Pulse Telco CRM & Subscribers Domain"
  description                = "Pulse Telco CRM Domain: Subscriber profiles, tenure, segments, and active mobile/fiber plans. Owned by CRM Analytics Team."
  location                   = var.bq_location
  delete_contents_on_destroy = true
  labels                     = merge(var.labels, { data_domain = "crm" })
  depends_on                 = [google_project_service.platform_apis]
}

resource "google_bigquery_dataset" "telco_billing" {
  project                    = var.project_id
  dataset_id                 = var.dataset_billing
  friendly_name              = "Pulse Telco Billing & Payments Domain"
  description                = "Pulse Telco Billing & Payments Domain: Monthly invoices, roaming charges, SLA credits, and payment gateway transactions. Owned by Revenue Assurance Team."
  location                   = var.bq_location
  delete_contents_on_destroy = true
  labels                     = merge(var.labels, { data_domain = "billing" })
  depends_on                 = [google_project_service.platform_apis]
}

resource "google_bigquery_dataset" "telco_network" {
  project                    = var.project_id
  dataset_id                 = var.dataset_network
  friendly_name              = "Pulse Telco Network Operations & RAN Telemetry Domain"
  description                = "Pulse Telco Network Operations Domain: 5G/LTE cell tower capacity, latency, packet loss, and NOC outage incidents. Owned by Network Engineering Team."
  location                   = var.bq_location
  delete_contents_on_destroy = true
  labels                     = merge(var.labels, { data_domain = "network" })
  depends_on                 = [google_project_service.platform_apis]
}

resource "google_bigquery_table" "subscribers" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.telco_crm.dataset_id
  table_id            = "subscribers"
  description         = "Master subscriber directory with segment, city, home cell tower, churn risk score (0-1), and GDPR consent flags."
  deletion_protection = false
  labels              = merge(var.labels, { data_domain = "crm", gdpr_tier = "confidential-pii" })

  schema = jsonencode([
    { name = "subscriber_id", type = "STRING", mode = "REQUIRED", description = "Unique Pulse Telco subscriber identifier (e.g., SUB-1001). Primary join key across CRM and Billing." },
    { name = "full_name", type = "STRING", mode = "NULLABLE", description = "Subscriber full name (GDPR Confidential PII)." },
    { name = "email", type = "STRING", mode = "NULLABLE", description = "Primary contact email address (GDPR Confidential PII)." },
    { name = "phone_msisdn", type = "STRING", mode = "NULLABLE", description = "E.164 mobile subscriber ISDN number (+420...)." },
    { name = "segment", type = "STRING", mode = "NULLABLE", description = "Commercial segment: Consumer, Premium, SMB, or Enterprise_VIP." },
    { name = "city_code", type = "STRING", mode = "NULLABLE", description = "City code: PRG, BRN, OVA, BTS, or VIE." },
    { name = "city_name", type = "STRING", mode = "NULLABLE", description = "City display name." },
    { name = "primary_tower_id", type = "STRING", mode = "NULLABLE", description = "Primary serving 5G/LTE cell tower ID (joins with telco_network.cell_towers.tower_id)." },
    { name = "tenure_months", type = "INTEGER", mode = "NULLABLE", description = "Months since subscriber activation." },
    { name = "churn_risk_score", type = "FLOAT", mode = "NULLABLE", description = "ML churn propensity score [0.0-1.0]. High Churn Risk is defined as churn_risk_score >= 0.70." },
    { name = "churn_risk_tier", type = "STRING", mode = "NULLABLE", description = "Categorical churn tier: HIGH (>=0.70), MEDIUM (0.40-0.69), LOW (<0.40)." },
    { name = "vip_flag", type = "BOOLEAN", mode = "NULLABLE", description = "True if subscriber belongs to Premium or Enterprise_VIP segment." },
    { name = "gdpr_marketing_consent", type = "BOOLEAN", mode = "NULLABLE", description = "True if subscriber opted in to proactive retention offers under EU GDPR." },
    { name = "account_status", type = "STRING", mode = "NULLABLE", description = "Account lifecycle state: ACTIVE or SUSPENDED." },
    { name = "created_date", type = "DATE", mode = "NULLABLE", description = "Account activation date." }
  ])
}

resource "google_bigquery_table" "subscriptions" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.telco_crm.dataset_id
  table_id            = "subscriptions"
  description         = "Active mobile 5G, fiber broadband, and B2B tariff subscriptions linked to subscriber_id."
  deletion_protection = false
  labels              = merge(var.labels, { data_domain = "crm" })

  schema = jsonencode([
    { name = "subscription_id", type = "STRING", mode = "REQUIRED", description = "Unique tariff subscription ID (e.g., PLAN-2001)." },
    { name = "subscriber_id", type = "STRING", mode = "REQUIRED", description = "Foreign key to telco_crm.subscribers.subscriber_id." },
    { name = "plan_name", type = "STRING", mode = "NULLABLE", description = "Commercial tariff plan name (e.g., Pulse 5G Unlimited Max, Pulse Enterprise Fiber 10G)." },
    { name = "plan_category", type = "STRING", mode = "NULLABLE", description = "Service category: Mobile_5G, Fiber_Home, Converged, or B2B_Dedicated." },
    { name = "monthly_fee_eur", type = "FLOAT", mode = "NULLABLE", description = "Contracted base monthly recurring charge in EUR." },
    { name = "data_allowance_gb", type = "INTEGER", mode = "NULLABLE", description = "Monthly high-speed data allowance in GB." },
    { name = "data_used_gb", type = "FLOAT", mode = "NULLABLE", description = "Current billing cycle data consumption in GB." },
    { name = "roaming_zone", type = "STRING", mode = "NULLABLE", description = "Included roaming scope: EU_EEA or WORLD_BIZ." },
    { name = "contract_end_date", type = "DATE", mode = "NULLABLE", description = "Fixed-term contract expiration date." },
    { name = "status", type = "STRING", mode = "NULLABLE", description = "Subscription status (ACTIVE)." }
  ])
}

resource "google_bigquery_table" "invoices" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.telco_billing.dataset_id
  table_id            = "invoices"
  description         = "Monthly customer invoices with base charges, roaming/overage fees, SLA credits, and payment status."
  deletion_protection = false
  labels              = merge(var.labels, { data_domain = "billing" })

  schema = jsonencode([
    { name = "invoice_id", type = "STRING", mode = "REQUIRED", description = "Unique monthly invoice identifier (e.g., INV-202608-1001)." },
    { name = "subscriber_id", type = "STRING", mode = "REQUIRED", description = "Foreign key to telco_crm.subscribers.subscriber_id." },
    { name = "billing_period", type = "STRING", mode = "NULLABLE", description = "Billing month in YYYY-MM format." },
    { name = "base_amount_eur", type = "FLOAT", mode = "NULLABLE", description = "Base monthly plan charge in EUR." },
    { name = "overage_eur", type = "FLOAT", mode = "NULLABLE", description = "Data overage charge beyond allowance in EUR." },
    { name = "roaming_eur", type = "FLOAT", mode = "NULLABLE", description = "Non-EU international roaming fees in EUR." },
    { name = "sla_credit_eur", type = "FLOAT", mode = "NULLABLE", description = "Goodwill or SLA outage credit applied in EUR." },
    { name = "total_amount_eur", type = "FLOAT", mode = "NULLABLE", description = "Net billed invoice amount in EUR (used for Net Billed ARPU)." },
    { name = "status", type = "STRING", mode = "NULLABLE", description = "Invoice status: PAID, OVERDUE, or DISPUTED." },
    { name = "due_date", type = "DATE", mode = "NULLABLE", description = "Invoice payment due date." },
    { name = "dispute_reason", type = "STRING", mode = "NULLABLE", description = "Reason for customer billing dispute if status=DISPUTED." }
  ])
}

resource "google_bigquery_table" "payment_transactions" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.telco_billing.dataset_id
  table_id            = "payment_transactions"
  description         = "Payment gateway attempts, failure codes, and billing adjustment notes."
  deletion_protection = false
  labels              = merge(var.labels, { data_domain = "billing", gdpr_tier = "pci-restricted" })

  schema = jsonencode([
    { name = "transaction_id", type = "STRING", mode = "REQUIRED", description = "Unique payment gateway transaction ID (e.g., TXN-90001)." },
    { name = "invoice_id", type = "STRING", mode = "REQUIRED", description = "Foreign key to telco_billing.invoices.invoice_id." },
    { name = "subscriber_id", type = "STRING", mode = "REQUIRED", description = "Foreign key to telco_crm.subscribers.subscriber_id." },
    { name = "payment_method", type = "STRING", mode = "NULLABLE", description = "Payment instrument: SEPA_Direct_Debit, Visa_Card, Apple_Pay, or Bank_Transfer." },
    { name = "amount_eur", type = "FLOAT", mode = "NULLABLE", description = "Transaction amount in EUR." },
    { name = "status", type = "STRING", mode = "NULLABLE", description = "Gateway result: SUCCEEDED, FAILED, or PENDING_DISPUTE." },
    { name = "failure_code", type = "STRING", mode = "NULLABLE", description = "ISO/Gateway failure code when status != SUCCEEDED." },
    { name = "transaction_ts", type = "TIMESTAMP", mode = "NULLABLE", description = "UTC timestamp of payment processing." },
    { name = "customer_note", type = "STRING", mode = "NULLABLE", description = "Unstructured customer comment submitted with payment or dispute." }
  ])
}

resource "google_bigquery_table" "cell_towers" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.telco_network.dataset_id
  table_id            = "cell_towers"
  description         = "5G/LTE radio access network (RAN) cell site inventory and real-time health KPIs."
  deletion_protection = false
  labels              = merge(var.labels, { data_domain = "network" })

  schema = jsonencode([
    { name = "tower_id", type = "STRING", mode = "REQUIRED", description = "Unique cell site identifier (e.g., TWR-PRG-02)." },
    { name = "city_code", type = "STRING", mode = "NULLABLE", description = "City code: PRG, BRN, OVA, BTS, or VIE." },
    { name = "city_name", type = "STRING", mode = "NULLABLE", description = "City display name." },
    { name = "district", type = "STRING", mode = "NULLABLE", description = "Neighborhood or business district covered by the cell site." },
    { name = "technology", type = "STRING", mode = "NULLABLE", description = "Radio technology: 5G_SA_3500MHz, 5G_NSA_2100MHz, or LTE_A_800MHz." },
    { name = "status", type = "STRING", mode = "NULLABLE", description = "Operational state: HEALTHY or DEGRADED." },
    { name = "utilization_pct", type = "FLOAT", mode = "NULLABLE", description = "Current PRB (Physical Resource Block) utilization percentage." },
    { name = "avg_latency_ms", type = "FLOAT", mode = "NULLABLE", description = "Average RAN round-trip latency in milliseconds." },
    { name = "packet_loss_pct", type = "FLOAT", mode = "NULLABLE", description = "Packet loss percentage across the backhaul interface." },
    { name = "active_connections", type = "INTEGER", mode = "NULLABLE", description = "Concurrent attached UE sessions." },
    { name = "backhaul_type", type = "STRING", mode = "NULLABLE", description = "Transport link type: Dual-100G-Fiber, Single-10G-Fiber, or Microwave-Backup." },
    { name = "last_maintenance_date", type = "DATE", mode = "NULLABLE", description = "Date of most recent field inspection." }
  ])
}

resource "google_bigquery_table" "network_incidents" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.telco_network.dataset_id
  table_id            = "network_incidents"
  description         = "Active and resolved NOC incidents linked to cell_towers via tower_id."
  deletion_protection = false
  labels              = merge(var.labels, { data_domain = "network" })

  schema = jsonencode([
    { name = "incident_id", type = "STRING", mode = "REQUIRED", description = "Unique NOC incident ticket ID (e.g., INC-7001)." },
    { name = "tower_id", type = "STRING", mode = "REQUIRED", description = "Affected cell site ID (joins with telco_network.cell_towers.tower_id)." },
    { name = "severity", type = "STRING", mode = "NULLABLE", description = "Incident severity: P1_CRITICAL, P2_MAJOR, or P3_MINOR." },
    { name = "incident_type", type = "STRING", mode = "NULLABLE", description = "Fault category (e.g., FIBER_BACKHAUL_CUT, RAN_PRB_CONGESTION)." },
    { name = "status", type = "STRING", mode = "NULLABLE", description = "Ticket lifecycle status: OPEN, INVESTIGATING, MITIGATING, or RESOLVED." },
    { name = "started_ts", type = "TIMESTAMP", mode = "NULLABLE", description = "Incident start timestamp (UTC)." },
    { name = "resolved_ts", type = "TIMESTAMP", mode = "NULLABLE", description = "Incident resolution timestamp (UTC), null if still active." },
    { name = "affected_subscribers_est", type = "INTEGER", mode = "NULLABLE", description = "Estimated number of impacted subscribers on the tower." },
    { name = "root_cause_summary", type = "STRING", mode = "NULLABLE", description = "Engineering root cause and remediation notes." }
  ])
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Knowledge Catalog Aspect Types (Semantic & Governance Layer)
# ─────────────────────────────────────────────────────────────────────────────
resource "google_dataplex_aspect_type" "telco_governance" {
  project        = var.project_id
  location       = var.dataplex_location
  aspect_type_id = "telco-governance"
  display_name   = "Pulse Telco Data Governance & GDPR Classification"
  description    = "Domain ownership, GDPR PII classification, and row-level security guidance for AI agents."
  labels         = var.labels

  metadata_template = jsonencode({
    name = "TelcoGovernance"
    type = "record"
    recordFields = [
      {
        name        = "data_domain"
        type        = "string"
        index       = 1
        annotations = { description = "Owning Telco business domain (CRM, BILLING, NETWORK)" }
        constraints = { required = true }
      },
      {
        name        = "domain_owner"
        type        = "string"
        index       = 2
        annotations = { description = "Responsible data steward team email" }
        constraints = { required = true }
      },
      {
        name  = "gdpr_classification"
        type  = "enum"
        index = 3
        enumValues = [
          { name = "PUBLIC", index = 1 },
          { name = "INTERNAL_OPERATIONAL", index = 2 },
          { name = "CONFIDENTIAL_PII", index = 3 },
          { name = "PCI_RESTRICTED", index = 4 }
        ]
        constraints = { required = true }
      },
      {
        name        = "agent_access_policy"
        type        = "string"
        index       = 4
        annotations = { description = "Mandatory rule that AI agents must follow when querying this table" }
        constraints = { required = false }
      }
    ]
  })

  depends_on = [google_project_service.platform_apis]
}

resource "google_dataplex_aspect_type" "telco_semantics" {
  project        = var.project_id
  location       = var.dataplex_location
  aspect_type_id = "telco-semantics"
  display_name   = "Pulse Telco Business Semantics & KPI Rules"
  description    = "Canonical KPI formulas, primary join keys, and semantic query hints for conversational analytics agents."
  labels         = var.labels

  metadata_template = jsonencode({
    name = "TelcoSemantics"
    type = "record"
    recordFields = [
      {
        name        = "primary_join_key"
        type        = "string"
        index       = 1
        annotations = { description = "Primary entity join key (e.g., subscriber_id, tower_id, invoice_id)" }
        constraints = { required = true }
      },
      {
        name        = "canonical_kpi_formula"
        type        = "string"
        index       = 2
        annotations = { description = "Authoritative SQL formula for domain KPIs" }
        constraints = { required = true }
      },
      {
        name        = "freshness_sla"
        type        = "string"
        index       = 3
        annotations = { description = "Expected data freshness SLA" }
        constraints = { required = false }
      }
    ]
  })

  depends_on = [google_project_service.platform_apis]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. GEAP Artifact Staging Bucket (EU)
# ─────────────────────────────────────────────────────────────────────────────
resource "google_storage_bucket" "geap_staging" {
  project                     = var.project_id
  name                        = "${var.project_id}-${var.agent_name}-staging"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels
  depends_on                  = [google_project_service.platform_apis]
}

resource "google_storage_bucket_iam_member" "concierge_staging_admin" {
  bucket = google_storage_bucket.geap_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pulse_concierge.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Cloud Run Services (IAM Context MCP Server & Network Ops A2A Agent)
# ─────────────────────────────────────────────────────────────────────────────
resource "google_cloud_run_v2_service" "iam_context_mcp" {
  project             = var.project_id
  name                = "pulse-iam-context-mcp"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = merge(var.labels, { component = "iam-mcp-server" })

  template {
    service_account = google_service_account.iam_mcp.email
    containers {
      image = var.iam_mcp_image
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
    }
  }

  depends_on = [google_project_service.platform_apis]
}

resource "google_cloud_run_v2_service" "network_ops_agent" {
  project             = var.project_id
  name                = "pulse-network-ops-agent"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = merge(var.labels, { component = "network-ops-a2a-agent" })

  template {
    service_account = google_service_account.network_ops_agent.email
    containers {
      image = var.network_ops_agent_image
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOOGLE_CLOUD_LOCATION"
        value = var.model_location
      }
      env {
        name  = "MODEL"
        value = var.model_id
      }
    }
  }

  depends_on = [google_project_service.platform_apis]
}

resource "google_cloud_run_v2_service_iam_member" "concierge_invokes_iam_mcp" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.iam_context_mcp.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pulse_concierge.email}"
}

resource "google_cloud_run_v2_service_iam_member" "concierge_invokes_network_ops" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.network_ops_agent.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pulse_concierge.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Knowledge Catalog Business Glossary & Canonical Telco KPI Terms
# ─────────────────────────────────────────────────────────────────────────────
resource "google_dataplex_glossary" "pulse_telco_glossary" {
  project      = var.project_id
  location     = var.dataplex_location
  glossary_id  = "pulse-telco-glossary"
  display_name = "Pulse Telco Enterprise Business Glossary"
  description  = "Authoritative Telco KPI definitions, entity join rules, and GDPR access guidance for conversational analytics agents."
  labels       = var.labels
  depends_on   = [google_project_service.platform_apis]
}

locals {
  glossary_terms = {
    "high-churn-risk" = {
      display_name = "High Churn Risk Subscriber"
      description  = "An ACTIVE subscriber in telco_crm.subscribers whose ML churn propensity score is >= 0.70 (churn_risk_tier = 'HIGH')."
    }
    "net-billed-arpu" = {
      display_name = "Net Billed ARPU (EUR)"
      description  = "Average revenue per active subscriber per billing period: SUM(total_amount_eur) / COUNT(DISTINCT subscriber_id) in telco_billing.invoices."
    }
    "delinquent-vs-disputed" = {
      display_name = "Delinquent vs Disputed Exposure"
      description  = "Delinquent exposure counts ONLY invoices where status = 'OVERDUE'. Invoices with status = 'DISPUTED' are tracked under Billing Dispute Resolution."
    }
    "degraded-cell-site" = {
      display_name = "Degraded Cell Site (RAN)"
      description  = "A 5G/LTE cell tower in telco_network.cell_towers where status = 'DEGRADED', utilization_pct > 85.0, or packet_loss_pct > 1.0."
    }
  }
}

resource "google_dataplex_glossary_term" "telco_kpis" {
  for_each     = local.glossary_terms
  project      = var.project_id
  location     = var.dataplex_location
  glossary_id  = google_dataplex_glossary.pulse_telco_glossary.glossary_id
  parent       = "projects/${var.project_id}/locations/${var.dataplex_location}/glossaries/${google_dataplex_glossary.pulse_telco_glossary.glossary_id}"
  term_id      = each.key
  display_name = each.value.display_name
  description  = each.value.description
  labels       = var.labels
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. Model Armor Regional Guardrail Templates (Input & Output)
# ─────────────────────────────────────────────────────────────────────────────
resource "google_model_armor_template" "pulse_guard_input" {
  project     = var.project_id
  location    = var.region
  template_id = "pulse-guard-input"
  labels      = var.labels

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "LOW_AND_ABOVE"
    }
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }
    rai_settings {
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
    }
  }

  template_metadata {
    log_template_operations            = true
    log_sanitize_operations            = true
    custom_prompt_safety_error_code    = 400
    custom_prompt_safety_error_message = "Prompt blocked by Pulse Telco security policy (Model Armor)."
  }

  depends_on = [google_project_service.platform_apis]
}

resource "google_model_armor_template" "pulse_guard_output" {
  project     = var.project_id
  location    = var.region
  template_id = "pulse-guard-output"
  labels      = var.labels

  filter_config {
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }
    rai_settings {
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
    }
  }

  template_metadata {
    log_template_operations                  = true
    log_sanitize_operations                  = true
    custom_llm_response_safety_error_code    = 400
    custom_llm_response_safety_error_message = "Response blocked by Pulse Telco security policy (Model Armor)."
  }

  depends_on = [google_project_service.platform_apis]
}

