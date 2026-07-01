terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = "europe-west1"
}

locals {
  env    = "staging"
  region = "europe-west1"
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
# Image paths: europe-west1-docker.pkg.dev/{project_id}/arkmask/api:{tag}
#              europe-west1-docker.pkg.dev/{project_id}/arkmask/workers:{tag}

resource "google_artifact_registry_repository" "arkmask" {
  repository_id = "arkmask"
  format        = "DOCKER"
  location      = local.region
  project       = var.project_id
  description   = "ArkMask Docker images (API + workers)"
}

# ── Secret Manager — single consolidated secret ───────────────────────────────
# One JSON secret per env replaces the previous four separate secrets.
# The backend reads ARKMASK_SECRET at startup and unpacks it.
#
# Secret structure:
# {
#   "firebase_credentials": { ...service account JSON... },
#   "stripe_secret_key":           "sk_test_...",
#   "stripe_webhook_secret":       "whsec_...",
#   "stripe_price_creator_monthly": "price_...",
#   "stripe_price_creator_annual":  "price_...",
#   "stripe_price_studio_monthly":  "price_...",
#   "stripe_price_studio_annual":   "price_..."
# }
#
# Populate the value after apply:
#   gcloud secrets versions add staging-arkmask-config --data-file=config.json

resource "google_secret_manager_secret" "config" {
  secret_id = "staging-arkmask-config"
  project   = var.project_id
  replication {
    auto {}
  }
}

# ── GCS media bucket ──────────────────────────────────────────────────────────

module "gcs" {
  source      = "../../modules/gcs"
  project_id  = var.project_id
  region      = "EUROPE-WEST1"
  bucket_name = "arkmask-media-staging"
  # Allow Terraform to destroy the staging bucket (useful for full env teardown).
  force_destroy = true
}

# ── IAM ───────────────────────────────────────────────────────────────────────

module "iam" {
  source            = "../../modules/iam"
  project_id        = var.project_id
  env               = local.env
  media_bucket_name = module.gcs.bucket_name
}

# ── Cloud Tasks ───────────────────────────────────────────────────────────────

module "cloud_tasks" {
  source     = "../../modules/cloud-tasks"
  project_id = var.project_id
  env        = local.env
  region     = local.region
  # Reduced concurrency for staging — avoids accidental API quota burn.
  image_queue_concurrency = 5
  video_queue_concurrency = 3
  merge_queue_concurrency = 2
}

# ── Cloud Run — API ───────────────────────────────────────────────────────────

module "api" {
  source     = "../../modules/cloud-run"
  project_id = var.project_id
  region     = local.region

  name  = "staging-arkmask-api"
  # Placeholder — CI/CD (gcloud run deploy) replaces this on first push.
  # lifecycle.ignore_changes on image means Terraform never reverts it.
  image = "us-docker.pkg.dev/cloudrun/container/hello"

  service_account_email = module.iam.api_sa_email
  allow_unauthenticated = true

  # Staging: scale-to-zero to minimise cost between test runs.
  min_instances   = 0
  max_instances   = 3
  cpu             = "1"
  memory          = "512Mi"
  timeout_seconds = 60

  env_vars = {
    APP_ENV                  = "staging"
    STORAGE_BUCKET           = module.gcs.bucket_name
    FIREBASE_PROJECT_ID      = var.project_id
    GCP_PROJECT_ID           = var.project_id
    GCP_REGION               = local.region
    CLOUD_TASKS_IMAGE_QUEUE  = module.cloud_tasks.image_queue_name
    CLOUD_TASKS_VIDEO_QUEUE  = module.cloud_tasks.video_queue_name
    CLOUD_TASKS_MERGE_QUEUE  = module.cloud_tasks.merge_queue_name
    WORKERS_SERVICE_URL      = module.workers.service_url
    # OIDC identity Cloud Tasks presents when calling the workers service —
    # already granted roles/run.invoker on workers (see invoker_members below).
    API_SERVICE_ACCOUNT_EMAIL = module.iam.api_sa_email
  }

  secret_env_vars = {
    ARKMASK_SECRET = {
      secret  = google_secret_manager_secret.config.secret_id
      version = "latest"
    }
  }

  # Explicit dependency: Cloud Run needs the api SA's secretAccessor grant
  # (module.iam.api_secretmanager) to exist and propagate before the revision
  # starts. The implicit dependency via service_account_email only tracks the
  # SA resource itself, not its IAM bindings, so without this Cloud Run can
  # race ahead and fail with "Permission denied on secret".
  depends_on = [module.iam]
}

# ── Cloud Run — Workers ───────────────────────────────────────────────────────
# Workers are invoked internally by Cloud Tasks using OIDC — not publicly accessible.

module "workers" {
  source     = "../../modules/cloud-run"
  project_id = var.project_id
  region     = local.region

  name  = "staging-arkmask-workers"
  # Placeholder — CI/CD (gcloud run deploy) replaces this on first push.
  # lifecycle.ignore_changes on image means Terraform never reverts it.
  image = "us-docker.pkg.dev/cloudrun/container/hello"

  service_account_email = module.iam.workers_sa_email
  allow_unauthenticated = false

  min_instances = 0
  max_instances = 5
  cpu           = "2"
  # 4 GiB for the merge worker (FFmpeg + scene video buffering).
  memory          = "4Gi"
  timeout_seconds = 1800 # 30 min — video generation and FFmpeg merge can take several minutes

  # Grant the API service account permission to invoke workers via Cloud Tasks OIDC.
  invoker_members = ["serviceAccount:${module.iam.api_sa_email}"]

  env_vars = {
    APP_ENV             = "staging"
    STORAGE_BUCKET      = module.gcs.bucket_name
    FIREBASE_PROJECT_ID = var.project_id
  }

  secret_env_vars = {
    ARKMASK_SECRET = {
      secret  = google_secret_manager_secret.config.secret_id
      version = "latest"
    }
  }

  # See note on module.api above — same IAM propagation race applies here,
  # and this is precisely the module whose secret access denial we hit.
  depends_on = [module.iam]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "api_url" {
  description = "Staging API base URL."
  value       = module.api.service_url
}

output "workers_url" {
  description = "Staging workers service URL (internal — not publicly accessible)."
  value       = module.workers.service_url
}
