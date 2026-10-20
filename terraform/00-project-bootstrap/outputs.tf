output "project_id" {
  description = "The created Google Cloud Project ID. Pass this as `project_id` to `01-telco-geap-platform`."
  value       = google_project.telco_workshop.project_id
}

output "project_number" {
  description = "The numeric Project Number of the created Google Cloud Project."
  value       = google_project.telco_workshop.number
}

output "next_step_command" {
  description = "Convenience command to apply the main platform module against this project."
  value       = "cd ../01-telco-geap-platform && terraform init && terraform apply -var=\"project_id=${google_project.telco_workshop.project_id}\""
}
