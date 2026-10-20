output "project_id" {
  description = "Google Cloud Project ID where the Pulse Telco GEAP platform is deployed."
  value       = var.project_id
}

output "project_number" {
  description = "Numeric Google Cloud Project Number."
  value       = data.google_project.current.number
}

output "bigquery_datasets" {
  description = "Provisioned multi-domain BigQuery datasets in EU."
  value = {
    crm     = google_bigquery_dataset.telco_crm.dataset_id
    billing = google_bigquery_dataset.telco_billing.dataset_id
    network = google_bigquery_dataset.telco_network.dataset_id
  }
}

output "knowledge_catalog_aspect_types" {
  description = "Provisioned Knowledge Catalog (Dataplex) Aspect Types."
  value = {
    governance = google_dataplex_aspect_type.telco_governance.name
    semantics  = google_dataplex_aspect_type.telco_semantics.name
  }
}

output "knowledge_catalog_glossary" {
  description = "Provisioned Knowledge Catalog (Dataplex) Business Glossary resource name."
  value       = google_dataplex_glossary.pulse_telco_glossary.name
}

output "model_armor_templates" {
  description = "Provisioned Regional Model Armor guardrail template resource names."
  value = {
    input_template  = google_model_armor_template.pulse_guard_input.name
    output_template = google_model_armor_template.pulse_guard_output.name
  }
}

output "service_accounts" {
  description = "Least-privilege Service Account emails for the multi-agent architecture."
  value = {
    pulse_concierge   = google_service_account.pulse_concierge.email
    iam_mcp           = google_service_account.iam_mcp.email
    network_ops_agent = google_service_account.network_ops_agent.email
  }
}

output "cloud_run_endpoints" {
  description = "Deployed Cloud Run URLs for the IAM Context MCP Server and Network Ops A2A Agent."
  value = {
    iam_context_mcp_url   = google_cloud_run_v2_service.iam_context_mcp.uri
    network_ops_agent_url = google_cloud_run_v2_service.network_ops_agent.uri
  }
}

output "staging_bucket" {
  description = "GCS staging bucket for GEAP Agent Runtime and Evaluation runs."
  value       = google_storage_bucket.geap_staging.url
}

