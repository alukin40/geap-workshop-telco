# Terraform Deployment — Pulse Telco GEAP Multi-Agent Platform

This directory provides a complete, production-grade **Infrastructure-as-Code (Terraform)** deployment of the **Pulse Telco Conversational Analytics & Multi-Agent Platform** on **Gemini Enterprise Agent Platform (GEAP)**.

It is split into two independent Terraform root modules so enterprise customers can deploy directly into their existing Google Cloud environment without needing Organization-level project creation permissions:

| Module | Audience | Purpose |
| :--- | :--- | :--- |
| **[`00-project-bootstrap/`](./00-project-bootstrap/)** | **Optional** (Instructors / Sandbox Admins) | Creates a brand-new Google Cloud Project, links a Billing Account, and enables seed bootstrap APIs. Outputs `project_id` and `project_number`. |
| **[`01-telco-geap-platform/`](./01-telco-geap-platform/)** | **Customer-Facing** (Primary Module) | Parameterized via `var.project_id` (`europe-west1` / `EU`). Provisions all 28 APIs, least-privilege Service Accounts & IAM, multi-domain BigQuery datasets & tables (`telco_crm`, `telco_billing`, `telco_network`), Knowledge Catalog Aspect Types (`telco-governance`, `telco-semantics`), GEAP staging bucket, and Cloud Run services (`pulse-iam-context-mcp` & `pulse-network-ops-agent`). |

---

## Option A: Deploy into an Existing GCP Project (Customer Standard)

```bash
cd terraform/01-telco-geap-platform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set project_id = "your-existing-project-id"

terraform init
terraform plan
terraform apply
```

## Option B: Create a Fresh GCP Project First (Optional Bootstrap)

```bash
# Step 1: Bootstrap a new GCP project
cd terraform/00-project-bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your billing_account and org_id / folder_id
terraform init
terraform apply

# Step 2: Deploy the Pulse Telco GEAP Platform into the new project
PROJECT_ID=$(terraform output -raw project_id)
cd ../01-telco-geap-platform
terraform init
terraform apply -var="project_id=${PROJECT_ID}"
```
