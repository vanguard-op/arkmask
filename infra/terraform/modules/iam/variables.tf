variable "project_id" {
  type = string
}

variable "env" {
  description = "Environment name (staging | prod)."
  type        = string
}

variable "media_bucket_name" {
  description = "Name of the GCS media bucket — used to scope storage IAM bindings."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format (e.g. myorg/arkmask). Used to scope Workload Identity Federation. Only created once (not per-env)."
  type        = string
}

variable "create_wif" {
  description = "Whether to create the Workload Identity Pool and Provider. Set true only in one env (prod) since the pool is project-scoped, not env-scoped."
  type        = bool
  default     = false
}
