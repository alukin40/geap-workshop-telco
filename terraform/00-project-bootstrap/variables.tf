variable "project_prefix" {
  description = "Prefix for the generated Google Cloud Project ID (e.g., 'pulse-telco-geap')."
  type        = string
  default     = "pulse-telco-geap"
}

variable "project_id" {
  description = "Explicit Google Cloud Project ID. Leave empty to auto-generate `<project_prefix>-<random_suffix>`."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Human-readable display name for the Google Cloud Project."
  type        = string
  default     = "GEAP Pulse Telco Workshop"
}

variable "billing_account" {
  description = "Billing Account ID to link to the newly created project (e.g., '012345-6789AB-CDEF01')."
  type        = string
}

variable "org_id" {
  description = "Optional Organization ID (numeric) under which to create the project. Mutually exclusive with folder_id."
  type        = string
  default     = ""
}

variable "folder_id" {
  description = "Optional Folder ID (numeric) under which to create the project. Mutually exclusive with org_id."
  type        = string
  default     = ""
}

variable "billing_project_id" {
  description = "Optional existing project ID for quota/billing override during bootstrap."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Resource labels applied to the Google Cloud project."
  type        = map(string)
  default = {
    environment = "workshop"
    workload    = "pulse-telco-geap"
    managed-by  = "terraform"
  }
}
