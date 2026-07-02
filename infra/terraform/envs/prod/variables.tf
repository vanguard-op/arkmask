variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "alert_email" {
  description = "Email to notify for Cloud Monitoring alerts. Leave empty to create alert policies without a notification channel (visible in console, no paging)."
  type        = string
  default     = ""
}
