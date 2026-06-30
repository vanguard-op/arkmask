# Remote state stored in GCS — create this bucket manually before first `terraform init`.
# Bucket name convention: {project-id}-tfstate
#
# gcloud storage buckets create gs://{project-id}-tfstate \
#   --location=europe-west1 \
#   --uniform-bucket-level-access
# gcloud storage buckets update gs://{project-id}-tfstate --versioning

terraform {
  backend "gcs" {
    # Replace with your actual GCP project ID.
    bucket = "arkmask-tfstate"
    prefix = "arkmask/staging"
  }
}
