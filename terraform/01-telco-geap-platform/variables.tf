variable "project_id" {
  description = "Target Google Cloud Project ID where the Pulse Telco GEAP platform will be deployed."
  type        = string
}

variable "region" {
  description = "Primary Google Cloud region for Agent Runtime, Cloud Run, Model Armor, and Agent Gateway."
  type        = string
  default     = "europe-west1"
}

variable "bq_location" {
  description = "BigQuery multi-region or region for Telco domain datasets (e.g., 'EU' or 'europe-west1')."
  type        = string
  default     = "EU"
}

variable "dataplex_location" {
  description = "Knowledge Catalog (Dataplex) location matching BigQuery datasets (lowercase, e.g., 'eu' or 'europe-west1')."
  type        = string
  default     = "eu"
}

variable "model_location" {
  description = "Gemini Enterprise Agent Platform (Vertex AI) endpoint location for Gemini 3.x models."
  type        = string
  default     = "eu"
}

variable "model_id" {
  description = "Default Gemini model ID used by the Pulse Telco orchestrator and domain sub-agents."
  type        = string
  default     = "gemini-3.8-flash"
}

variable "agent_name" {
  description = "Canonical resource prefix and agent identifier."
  type        = string
  default     = "pulse-concierge"
}

variable "dataset_crm" {
  description = "BigQuery dataset ID for the CRM domain (Subscribers & Subscriptions)."
  type        = string
  default     = "telco_crm"
}

variable "dataset_billing" {
  description = "BigQuery dataset ID for the Billing & Payments domain (Invoices & Transactions)."
  type        = string
  default     = "telco_billing"
}

variable "dataset_network" {
  description = "BigQuery dataset ID for the Network Operations domain (Cell Towers & Incidents)."
  type        = string
  default     = "telco_network"
}

variable "iam_mcp_image" {
  description = "Container image for the Pulse Telco IAM & User Context MCP Server on Cloud Run. Defaults to a lightweight Python base when built via Cloud Build."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "network_ops_agent_image" {
  description = "Container image for the Pulse Telco Network Operations A2A Agent on Cloud Run."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "labels" {
  description = "Common labels applied to all provisioned resources."
  type        = map(string)
  default = {
    workload   = "pulse-telco-geap"
    domain     = "telco-conversational-analytics"
    managed-by = "terraform"
  }
}
