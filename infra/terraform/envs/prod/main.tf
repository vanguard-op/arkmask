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
  env    = "prod"
  region = "europe-west1"
}

# ── Artifact Registry ─────────────────────────────────────────────────────────

resource "google_artifact_registry_repository" "arkmask" {
  repository_id = "arkmask"
  format        = "DOCKER"
  location      = local.region
  project       = var.project_id
  description   = "ArkMask Docker images (API + workers)"
}

# ── Secret Manager — single consolidated secret ───────────────────────────────

resource "google_secret_manager_secret" "config" {
  secret_id = "prod-arkmask-config"
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
  bucket_name = "arkmask-media-prod"
  # Never allow Terraform to destroy the prod media bucket automatically.
  force_destroy = false
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
  # Production concurrency — tuned for live user traffic.
  image_queue_concurrency = 20
  video_queue_concurrency = 10
  merge_queue_concurrency = 5
  text_queue_concurrency  = 30
}

# ── Cloud Run — API ───────────────────────────────────────────────────────────

module "api" {
  source     = "../../modules/cloud-run"
  project_id = var.project_id
  region     = local.region

  name  = "prod-arkmask-api"
  # Placeholder — CI/CD (gcloud run deploy) replaces this on first push.
  # lifecycle.ignore_changes on image means Terraform never reverts it.
  image = "us-docker.pkg.dev/cloudrun/container/hello"

  service_account_email = module.iam.api_sa_email
  allow_unauthenticated = true

  # 1 minimum instance in prod to eliminate cold-start latency for paying users.
  min_instances   = 1
  max_instances   = 20
  cpu             = "1"
  memory          = "512Mi"
  timeout_seconds = 60

  env_vars = {
    APP_ENV                  = "production"
    STORAGE_BUCKET           = module.gcs.bucket_name
    FIREBASE_PROJECT_ID      = var.project_id
    GCP_PROJECT_ID           = var.project_id
    GCP_REGION               = local.region
    CLOUD_TASKS_IMAGE_QUEUE  = module.cloud_tasks.image_queue_name
    CLOUD_TASKS_VIDEO_QUEUE  = module.cloud_tasks.video_queue_name
    CLOUD_TASKS_MERGE_QUEUE  = module.cloud_tasks.merge_queue_name
    CLOUD_TASKS_TEXT_QUEUE   = module.cloud_tasks.text_queue_name
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

module "workers" {
  source     = "../../modules/cloud-run"
  project_id = var.project_id
  region     = local.region

  name  = "prod-arkmask-workers"
  # Placeholder — CI/CD (gcloud run deploy) replaces this on first push.
  # lifecycle.ignore_changes on image means Terraform never reverts it.
  image = "us-docker.pkg.dev/cloudrun/container/hello"

  service_account_email = module.iam.workers_sa_email
  allow_unauthenticated = false

  min_instances   = 0
  max_instances   = 50
  cpu             = "2"
  memory          = "4Gi"
  timeout_seconds = 1800

  invoker_members = ["serviceAccount:${module.iam.api_sa_email}"]

  env_vars = {
    APP_ENV             = "production"
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

# ── Monitoring ──────────────────────────────────────────────────────────────

module "monitoring" {
  source     = "../../modules/monitoring"
  project_id = var.project_id
  env        = local.env
  region     = local.region

  alert_email           = var.alert_email
  api_service_name      = module.api.service_name
  workers_service_name  = module.workers.service_name
  cloud_tasks_queue_ids = [
    module.cloud_tasks.image_queue_name,
    module.cloud_tasks.video_queue_name,
    module.cloud_tasks.merge_queue_name,
    module.cloud_tasks.text_queue_name,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "api_url" {
  description = "Production API base URL."
  value       = module.api.service_url
}

output "workers_url" {
  description = "Production workers URL (internal)."
  value       = module.workers.service_url
}
