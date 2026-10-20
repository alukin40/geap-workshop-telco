output "project_id" {
  description = "Google Cloud Project ID"
  value       = var.project_id
}

output "region" {
  description = "Region of the regional services (Agent Runtime, Cloud Run, Agent Registry, Agent Gateway)"
  value       = var.region
}

output "iam_context_mcp_url" {
  description = "IAM Context MCP server on Cloud Run"
  value       = local.iam_mcp_url
}

output "network_ops_agent_url" {
  description = "NOC A2A agent on Cloud Run"
  value       = local.noc_url
}

output "model_armor_templates" {
  description = "Model Armor templates used by the in-process plugin (and the gateway, when enabled)"
  value       = { for k, t in google_model_armor_template.guard : k => t.id }
}

output "persona_service_accounts" {
  description = "Persona identities the agent's BigQuery tools act as (session user_id alex / elena)"
  value       = { for k, sa in google_service_account.personas : k => sa.email }
}

output "prod_telemetry_bucket" {
  description = "GCS bucket for pulse-concierge-prod OpenTelemetry traces and completions"
  value       = google_storage_bucket.prod_telemetry_bucket.url
}

output "prod_agent_state_file" {
  description = "Path to the isolated production agent deployment state JSON"
  value       = "${abspath(path.module)}/../pulse-concierge-prod/deployment_metadata.json"
}

output "agent_gateway" {
  description = "Egress Agent Gateway bound to pulse-concierge-prod (null when enable_agent_gateway = false)"
  value       = var.enable_agent_gateway ? google_network_services_agent_gateway.egress[0].id : null
}

output "agent_gateway_enforcement" {
  description = "IAP mode of the gateway (DRY_RUN logs would-be decisions, ENFORCED blocks)"
  value       = var.enable_agent_gateway ? var.agent_gateway_enforcement : null
}

output "agent_gateway_policy_principal" {
  description = "Agent Identity the gateway access policy is written for"
  value       = var.enable_agent_gateway ? local.agent_principal : null
}
