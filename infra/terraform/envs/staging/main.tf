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
# Docker repository for API and workers images.
# Image paths: europe-west1-docker.pkg.dev/{project_id}/arkmask/api:{tag}
#              europe-west1-docker.pkg.dev/{project_id}/arkmask/workers:{tag}

resource "google_artifact_registry_repository" "arkmask" {
  repository_id = "arkmask"
  format        = "DOCKER"
  location      = local.region
  project       = var.project_id
  description   = "ArkMask Docker images (API + workers)"
}

# ── Secret Manager secrets ────────────────────────────────────────────────────
# Terraform creates the secret resources; values are populated separately
# (manually via gcloud or in your secrets rotation process — never in code).

resource "google_secret_manager_secret" "db_url" {
  secret_id = "staging-arkmask-db-url"
  project   = var.project_id
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "firebase_credentials" {
  secret_id = "staging-arkmask-firebase-credentials"
  project   = var.project_id
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "stripe_secret_key" {
  secret_id = "staging-arkmask-stripe-secret-key"
  project   = var.project_id
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "stripe_webhook_secret" {
  secret_id = "staging-arkmask-stripe-webhook-secret"
  project   = var.project_id
  replication {
    auto {}
  }
}

# ── Networking ────────────────────────────────────────────────────────────────

module "networking" {
  source     = "../../modules/networking"
  project_id = var.project_id
  env        = local.env
  region     = local.region
  # Staging uses the minimum connector size to minimise cost.
  connector_machine_type  = "e2-micro"
  connector_max_instances = 3
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

# ── Cloud SQL ─────────────────────────────────────────────────────────────────

module "cloud_sql" {
  source      = "../../modules/cloud-sql"
  project_id  = var.project_id
  env         = local.env
  region      = local.region
  vpc_id      = module.networking.vpc_id
  db_password = var.db_password
  # Smaller tier for staging — cost-efficient; upgrade to n1-standard-2 in prod.
  instance_tier       = "db-g1-small"
  deletion_protection = false
}

# ── IAM ───────────────────────────────────────────────────────────────────────

module "iam" {
  source            = "../../modules/iam"
  project_id        = var.project_id
  env               = local.env
  media_bucket_name = module.gcs.bucket_name
  github_repo       = var.github_repo
  # WIF is created in prod only (project-scoped; avoid duplicate pool error).
  create_wif = false
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
  image = "${local.region}-docker.pkg.dev/${var.project_id}/arkmask/api:latest"

  service_account_email = module.iam.api_sa_email
  vpc_connector_id      = module.networking.connector_id
  allow_unauthenticated = true

  # Staging: scale-to-zero to minimise cost between test runs.
  min_instances   = 0
  max_instances   = 3
  cpu             = "1"
  memory          = "512Mi"
  timeout_seconds = 60

  env_vars = {
    APP_ENV                 = "staging"
    STORAGE_BUCKET          = module.gcs.bucket_name
    FIREBASE_PROJECT_ID     = var.project_id
    CLOUD_TASKS_IMAGE_QUEUE = module.cloud_tasks.image_queue_name
    CLOUD_TASKS_VIDEO_QUEUE = module.cloud_tasks.video_queue_name
    CLOUD_TASKS_MERGE_QUEUE = module.cloud_tasks.merge_queue_name
    WORKERS_SERVICE_URL     = module.workers.service_url
  }

  secret_env_vars = {
    DATABASE_URL = {
      secret  = google_secret_manager_secret.db_url.secret_id
      version = "latest"
    }
    FIREBASE_CREDENTIALS_JSON = {
      secret  = google_secret_manager_secret.firebase_credentials.secret_id
      version = "latest"
    }
    STRIPE_SECRET_KEY = {
      secret  = google_secret_manager_secret.stripe_secret_key.secret_id
      version = "latest"
    }
    STRIPE_WEBHOOK_SECRET = {
      secret  = google_secret_manager_secret.stripe_webhook_secret.secret_id
      version = "latest"
    }
  }
}

# ── Cloud Run — Workers ───────────────────────────────────────────────────────
# Workers are invoked internally by Cloud Tasks using OIDC — not publicly accessible.

module "workers" {
  source     = "../../modules/cloud-run"
  project_id = var.project_id
  region     = local.region

  name  = "staging-arkmask-workers"
  image = "${local.region}-docker.pkg.dev/${var.project_id}/arkmask/workers:latest"

  service_account_email = module.iam.workers_sa_email
  vpc_connector_id      = module.networking.connector_id
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
    DATABASE_URL = {
      secret  = google_secret_manager_secret.db_url.secret_id
      version = "latest"
    }
    FIREBASE_CREDENTIALS_JSON = {
      secret  = google_secret_manager_secret.firebase_credentials.secret_id
      version = "latest"
    }
  }
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

output "db_private_ip" {
  description = "Private IP of the Cloud SQL instance (for DATABASE_URL secret population)."
  value       = module.cloud_sql.private_ip
}
