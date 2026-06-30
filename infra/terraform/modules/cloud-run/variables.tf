variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "name" {
  description = "Cloud Run service name (e.g. staging-arkmask-api)."
  type        = string
}

variable "image" {
  description = "Full Docker image reference including tag (e.g. europe-west1-docker.pkg.dev/my-project/arkmask/api:latest)."
  type        = string
}

variable "service_account_email" {
  description = "Service account email that the Cloud Run service runs as."
  type        = string
}

variable "vpc_connector_id" {
  description = "ID of the serverless VPC connector for Cloud SQL access."
  type        = string
}

variable "min_instances" {
  description = "Minimum number of instances (0 = scale-to-zero)."
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum number of instances."
  type        = number
  default     = 10
}

variable "cpu" {
  description = "CPU allocation (e.g. '1', '2')."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory allocation (e.g. '512Mi', '2Gi')."
  type        = string
  default     = "512Mi"
}

variable "timeout_seconds" {
  description = "Request timeout in seconds. Workers need a high value for long-running FFmpeg/AI jobs."
  type        = number
  default     = 300
}

variable "allow_unauthenticated" {
  description = "Allow public (unauthenticated) access. True for the API; false for workers (Cloud Tasks uses OIDC)."
  type        = bool
  default     = false
}

variable "env_vars" {
  description = "Plain-text environment variables (non-sensitive)."
  type        = map(string)
  default     = {}
}

variable "secret_env_vars" {
  description = "Secret Manager-backed environment variables. Map of env var name → { secret: secret_id, version: '1' | 'latest' }."
  type = map(object({
    secret  = string
    version = string
  }))
  default = {}
}

variable "invoker_members" {
  description = "Additional IAM members to grant roles/run.invoker (e.g. Cloud Tasks SA for workers)."
  type        = list(string)
  default     = []
}
