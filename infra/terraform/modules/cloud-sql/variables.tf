variable "project_id" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "instance_tier" {
  description = "Cloud SQL machine tier. Use db-g1-small for staging, db-n1-standard-2 for prod."
  type        = string
}

variable "vpc_id" {
  description = "Self-link of the VPC network for private IP peering."
  type        = string
}

variable "db_password" {
  description = "Password for the arkmask Cloud SQL user. Store the value in Secret Manager; pass it in via a data source or terraform.tfvars (never commit the raw value)."
  type        = string
  sensitive   = true
}

variable "deletion_protection" {
  description = "Set to true in prod to prevent accidental instance deletion."
  type        = bool
  default     = true
}
