variable "project_id" {
  type = string
}

variable "env" {
  description = "Environment name (prod | staging) — used in alert display names."
  type        = string
}

variable "region" {
  type = string
}

variable "alert_email" {
  description = <<-EOT
    Email address to notify on alert. Leave empty to skip creating a
    notification channel — alert policies are still created (visible in
    Cloud Monitoring) but won't page anyone until this is set.
  EOT
  type    = string
  default = ""
}

variable "api_service_name" {
  description = "Cloud Run service name for the API (5xx alert target)."
  type        = string
}

variable "workers_service_name" {
  description = "Cloud Run service name for the workers (5xx alert target)."
  type        = string
}

variable "cloud_tasks_queue_ids" {
  description = "Cloud Tasks queue IDs to monitor for backlog depth (image/video/merge)."
  type        = list(string)
}
