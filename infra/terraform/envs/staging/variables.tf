variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format (e.g. myorg/arkmask)."
  type        = string
}

variable "db_password" {
  description = "Cloud SQL arkmask user password. Set via TF_VAR_db_password env var in CI — never commit the value."
  type        = string
  sensitive   = true
}
