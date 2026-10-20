# Module 00: Optional GCP Project Bootstrap (Instructor / Sandbox Use)

This optional Terraform module creates a fresh Google Cloud Project, attaches a Billing Account, and enables core bootstrap APIs (`serviceusage`, `cloudresourcemanager`, `iam`, `orgpolicy`).

> **Note for Customers**: If your organization already has a pre-provisioned Google Cloud Project, **skip this module** and go directly to [`../01-telco-geap-platform/`](../01-telco-geap-platform/), passing your existing `project_id`.

## Usage

```bash
cd terraform/00-project-bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your billing_account and org_id / folder_id

terraform init
terraform apply
```

After `terraform apply` finishes, pass the output `project_id` into `../01-telco-geap-platform`:

```bash
PROJECT_ID=$(terraform output -raw project_id)
cd ../01-telco-geap-platform
terraform init
terraform apply -var="project_id=${PROJECT_ID}"
```
