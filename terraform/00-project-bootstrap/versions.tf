terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

provider "google" {
  billing_project       = var.billing_project_id != "" ? var.billing_project_id : null
  user_project_override = var.billing_project_id != "" ? true : false
}
