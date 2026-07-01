variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "env" {
  description = "Environment name (staging | prod). Used as a name prefix."
  type        = string
}

variable "region" {
  description = "GCP region for all resources."
  type        = string
  default     = "europe-west1"
}

variable "subnet_cidr" {
  description = "CIDR block for the VPC subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "connector_machine_type" {
  description = "Machine type for the serverless VPC connector."
  type        = string
  default     = "e2-micro"
}

variable "connector_max_instances" {
  description = "Maximum number of serverless VPC connector instances."
  type        = number
  default     = 3
}
