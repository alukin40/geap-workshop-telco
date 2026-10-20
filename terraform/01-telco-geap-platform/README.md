# Module 01: Customer-Facing Pulse Telco GEAP Multi-Agent Platform

This Terraform module deploys the foundational **Pulse Telco Conversational Analytics & Multi-Agent Platform** into an **existing Google Cloud Project** (`var.project_id`) with strict **EU Data Residency**.

## What This Module Provisions

1. **Google Cloud APIs (`google_project_service`)**:
   Enables BigQuery, Knowledge Catalog (`dataplex.googleapis.com`), Gemini Enterprise Agent Platform (`aiplatform.googleapis.com`), Agent Registry (`agentregistry.googleapis.com`), API Registry (`cloudapiregistry.googleapis.com`), Cloud Run (`run.googleapis.com`), Model Armor (`modelarmor.googleapis.com`), Cloud DLP (`dlp.googleapis.com`), Network Services (`networkservices.googleapis.com`), and Cloud Trace/Telemetry.
2. **Least-Privilege Service Accounts & IAM (`google_service_account`, `google_project_iam_member`)**:
   - `pulse-concierge-sa`: Identity for the root orchestrator and domain sub-agents (`roles/aiplatform.user`, `roles/bigquery.dataViewer`, `roles/bigquery.jobUser`, `roles/dataplex.catalogViewer`, `roles/modelarmor.user`, `roles/cloudtrace.agent`).
   - `pulse-iam-mcp-sa`: Identity for the `pulse-iam-context-mcp` Cloud Run server.
   - `pulse-network-ops-sa`: Identity for the remote A2A `pulse-network-ops-agent` Cloud Run service.
3. **Multi-Domain BigQuery Warehouse (`EU`)**:
   - `telco_crm`: `subscribers` and `subscriptions` tables with full column-level semantic descriptions.
   - `telco_billing`: `invoices` and `payment_transactions` tables.
   - `telco_network`: `cell_towers` and `network_incidents` tables.
4. **Knowledge Catalog Semantic & Governance Layer (`eu`)**:
   - `telco-governance` Aspect Type (domain owner, GDPR classification, agent access policy).
   - `telco-semantics` Aspect Type (primary join key, canonical KPI SQL formula, freshness SLA).
5. **Cloud Run Services & IAM Invoker Bindings (`europe-west1`)**:
   - `pulse-iam-context-mcp` (MCP Server for user token resolution & BigQuery dataset RBAC).
   - `pulse-network-ops-agent` (Remote A2A Network Operations specialist agent).
6. **GEAP Staging Bucket (`europe-west1`)**:
   - Uniform bucket-level access GCS bucket for Agent Engine & Evaluation artifacts.

## Quickstart (Customer Environment)

```bash
cd terraform/01-telco-geap-platform
cp terraform.tfvars.example terraform.tfvars
# Set project_id = "your-gcp-project-id" in terraform.tfvars

terraform init
terraform plan
terraform apply
```

### Building & Deploying the Cloud Run Container Images

Before or after running `terraform apply`, build the two service images from the repository root using Cloud Build and pass them to Terraform:

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="europe-west1"

gcloud builds submit ../../mocks/telco-iam-context-mcp \
  --tag "${REGION}-docker.pkg.dev/${PROJECT_ID}/cloud-run-source-deploy/pulse-iam-context-mcp:latest" \
  --project "${PROJECT_ID}"

gcloud builds submit ../../mocks/telco-network-ops-agent \
  --tag "${REGION}-docker.pkg.dev/${PROJECT_ID}/cloud-run-source-deploy/pulse-network-ops-agent:latest" \
  --project "${PROJECT_ID}"

terraform apply \
  -var="project_id=${PROJECT_ID}" \
  -var="iam_mcp_image=${REGION}-docker.pkg.dev/${PROJECT_ID}/cloud-run-source-deploy/pulse-iam-context-mcp:latest" \
  -var="network_ops_agent_image=${REGION}-docker.pkg.dev/${PROJECT_ID}/cloud-run-source-deploy/pulse-network-ops-agent:latest"
```
