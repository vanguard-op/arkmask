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
