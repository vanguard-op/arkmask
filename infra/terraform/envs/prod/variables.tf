variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format."
  type        = string
}

variable "db_password" {
  description = "Cloud SQL password. Set via TF_VAR_db_password in CI."
  type        = string
  sensitive   = true
}
