resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  effective_project_id = var.project_id != "" ? var.project_id : "${var.project_prefix}-${random_id.suffix.hex}"
}

resource "google_project" "telco_workshop" {
  name                = var.project_name
  project_id          = local.effective_project_id
  billing_account     = var.billing_account
  org_id              = var.org_id != "" && var.folder_id == "" ? var.org_id : null
  folder_id           = var.folder_id != "" ? var.folder_id : null
  labels              = var.labels
  auto_create_network = true
  deletion_policy     = "DELETE"
}

resource "google_project_service" "seed_apis" {
  for_each = toset([
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudbilling.googleapis.com",
    "iam.googleapis.com",
    "orgpolicy.googleapis.com",
  ])

  project            = google_project.telco_workshop.project_id
  service            = each.value
  disable_on_destroy = false
}
