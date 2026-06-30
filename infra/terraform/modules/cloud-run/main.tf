# Cloud Run module — generic service definition used for both API and workers.
#
# No VPC connector needed — all dependencies (Firestore, GCS, Cloud Tasks)
# are reached over HTTPS without private networking.
#
# Key differences between API and workers:
#   API:     allow_unauthenticated=true, low timeout, 1 min instance in prod
#   Workers: allow_unauthenticated=false, high timeout (1800s for FFmpeg),
#            higher memory (4Gi for merge worker), invoked via Cloud Tasks OIDC
#
# Image lifecycle:
#   Terraform creates the service once using var.image (a public placeholder on
#   first apply if the real image does not yet exist in Artifact Registry).
#   After that, the GitHub Actions deploy workflow owns the image — it calls
#   `gcloud run deploy` to update the revision.  The ignore_changes lifecycle
#   rule prevents Terraform from ever reverting the image CI/CD deployed.

resource "google_cloud_run_v2_service" "service" {
  name     = var.name
  location = var.region
  project  = var.project_id

  # Must be false to allow `terraform destroy` to remove the service.
  # The Google provider sets this to true by default in recent versions.
  deletion_protection = false

  # Ingress: allow all for API; internal-only for workers (Cloud Tasks is internal).
  ingress = var.allow_unauthenticated ? "INGRESS_TRAFFIC_ALL" : "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = var.service_account_email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Workers run long FFmpeg + AI provider calls; API is fast (< 5 s for sync endpoints).
    timeout = "${var.timeout_seconds}s"

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        # Allow CPU boost on startup — reduces cold-start latency.
        cpu_idle          = false
        startup_cpu_boost = true
      }

      # Plain-text environment variables (app env, bucket name, etc.).
      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      # Secret Manager-backed environment variables (DB password, Firebase creds, Stripe keys).
      # Values are injected at container start; never appear in logs or the Cloud Run console.
      dynamic "env" {
        for_each = var.secret_env_vars
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value.secret
              version = env.value.version
            }
          }
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    # CI/CD (gcloud run deploy) owns the image after the first apply.
    # Without this, every `terraform apply` would revert the image back to
    # whatever is in var.image, undoing the latest CI/CD deployment.
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }
}

# Public access for the API service.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count    = var.allow_unauthenticated ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Additional invokers (e.g. Cloud Tasks SA for workers).
resource "google_cloud_run_v2_service_iam_member" "extra_invokers" {
  for_each = toset(var.invoker_members)
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = each.value
}
