variable "project_id" {
  type = string
}

variable "region" {
  description = "GCS bucket location (co-located with Cloud Run / Cloud SQL in europe-west1)."
  type        = string
  default     = "EUROPE-WEST1"
}

variable "bucket_name" {
  description = "Globally unique name for the media bucket (e.g. arkmask-media-prod)."
  type        = string
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket even if it contains objects. Set true only in staging; always false in prod."
  type        = bool
  default     = false
}
