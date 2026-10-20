variable "project_id" {
  description = "Google Cloud project ID to deploy the full Pulse Telco reference solution into (can be empty)."
  type        = string
}

variable "region" {
  description = "The one region for regional services: Agent Runtime, Cloud Run (MCP + NOC agent), Agent Registry, Agent Gateway."
  type        = string
  default     = "europe-west4"
}

variable "model_location" {
  description = "Gemini text model location (EU multi-region endpoint)."
  type        = string
  default     = "eu"
}

variable "live_location" {
  description = "Gemini Live API (voice) location (EU multi-region endpoint)."
  type        = string
  default     = "eu"
}

variable "bq_location" {
  description = "BigQuery dataset location (EU multi-region). Knowledge Catalog uses the matching lower-case location (eu)."
  type        = string
  default     = "EU"
}

variable "model_armor_location" {
  description = "Model Armor template location. null = same as region."
  type        = string
  default     = null
}

variable "agent_name" {
  description = "Display name and identifier for the standalone production reference agent."
  type        = string
  default     = "pulse-concierge-prod"
}

variable "deploy_agent_runtime" {
  description = "Whether Terraform should package and deploy pulse-concierge-prod to Agent Runtime via agents-cli deploy."
  type        = bool
  default     = true
}

# --- Optional Agent Gateway (egress governance) -------------------------------------------------

variable "enable_agent_gateway" {
  description = "Create the egress Agent Gateway stack (pulse-prod-egress-gateway + IAP/UAP policy + optional Model Armor) and bind pulse-concierge-prod to it. false = agent deployed without any gateway."
  type        = bool
  default     = false
}

variable "agent_gateway_enforcement" {
  description = "IAP authorization mode of the gateway: DRY_RUN (log would-be decisions, never block) or ENFORCED (deny what the access policy does not allow)."
  type        = string
  default     = "DRY_RUN"

  validation {
    condition     = contains(["DRY_RUN", "ENFORCED"], var.agent_gateway_enforcement)
    error_message = "agent_gateway_enforcement must be DRY_RUN or ENFORCED."
  }
}

variable "agent_gateway_model_armor" {
  description = "Attach Model Armor (CONTENT_AUTHZ) to the gateway so MCP / A2A payloads are screened on the wire. Only used when enable_agent_gateway = true."
  type        = bool
  default     = true
}

variable "apply_org_policy_overrides" {
  description = "Project-level org-policy overrides the gateway needs: iam.managed.disableAccessPolicyBinding=false (enforced by default in new orgs; without it the per-tool access policy cannot be bound) and, with Model Armor, iam.allowedPolicyMemberDomains=allowAll (the gateway's Google-managed service account is outside your domain). Needs orgpolicy.policyAdmin; enable only in orgs you administer (e.g. Argolis)."
  type        = bool
  default     = false
}
