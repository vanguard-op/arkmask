# IAM module — service accounts, role bindings, and Workload Identity Federation.
#
# Three service accounts:
#   arkmask-api-sa      — runs the Cloud Run API service
#   arkmask-workers-sa  — runs the Cloud Run workers service (image/video/merge)
#   arkmask-github-sa   — used by GitHub Actions for CI/CD (deploy + image push)
#
# Workload Identity Federation (WIF) lets GitHub Actions authenticate to GCP without
# storing long-lived service account JSON keys as secrets. WIF is project-scoped so
# it is created only once (set create_wif = true in prod env only).

# ── Service accounts ──────────────────────────────────────────────────────────

resource "google_service_account" "api" {
  account_id   = "${var.env}-arkmask-api"
  display_name = "ArkMask API (${var.env})"
  project      = var.project_id
}

resource "google_service_account" "workers" {
  account_id   = "${var.env}-arkmask-workers"
  display_name = "ArkMask Workers (${var.env})"
  project      = var.project_id
}

# GitHub Actions SA — shared across envs; created only in prod to avoid duplication.
resource "google_service_account" "github" {
  count        = var.create_wif ? 1 : 0
  account_id   = "arkmask-github-actions"
  display_name = "ArkMask GitHub Actions CI/CD"
  project      = var.project_id
}

# ── API service account roles ─────────────────────────────────────────────────

# Read secrets from Secret Manager (DB password, Firebase credentials, Stripe keys).
resource "google_project_iam_member" "api_secretmanager" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.api.email}"
}

# Read/write Firestore (project content, user profiles, jobs, usage events).
resource "google_project_iam_member" "api_datastore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.api.email}"
}

# Enqueue jobs to Cloud Tasks queues (image-queue, video-queue, merge-queue).
resource "google_project_iam_member" "api_cloudtasks_enqueuer" {
  project = var.project_id
  role    = "roles/cloudtasks.enqueuer"
  member  = "serviceAccount:${google_service_account.api.email}"
}

# Send FCM push notifications via Firebase Admin SDK.
resource "google_project_iam_member" "api_firebase_messaging" {
  project = var.project_id
  role    = "roles/firebase.sdkAdminServiceAgent"
  member  = "serviceAccount:${google_service_account.api.email}"
}

# Read/write GCS media bucket (presigned URL generation + project deletion cleanup).
resource "google_storage_bucket_iam_member" "api_storage" {
  bucket = var.media_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.api.email}"
}

# ── Workers service account roles ─────────────────────────────────────────────

resource "google_project_iam_member" "workers_secretmanager" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.workers.email}"
}

# Update gcs_image_path, gcs_video_path, gcs_final_path on completion.
resource "google_project_iam_member" "workers_datastore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.workers.email}"
}

# Send FCM push on job completion (image/video/merge).
resource "google_project_iam_member" "workers_firebase_messaging" {
  project = var.project_id
  role    = "roles/firebase.sdkAdminServiceAgent"
  member  = "serviceAccount:${google_service_account.workers.email}"
}

# Read reference images from GCS; write generated images/videos/final.mp4 to GCS.
resource "google_storage_bucket_iam_member" "workers_storage" {
  bucket = var.media_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.workers.email}"
}

# ── Workload Identity Federation (GitHub Actions → GCP) ───────────────────────
# Only created in prod (create_wif = true) since the pool is project-scoped.

resource "google_iam_workload_identity_pool" "github" {
  count                     = var.create_wif ? 1 : 0
  workload_identity_pool_id = "arkmask-github-pool"
  display_name              = "ArkMask GitHub Actions"
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count                              = var.create_wif ? 1 : 0
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "arkmask-github-provider"
  project                            = var.project_id
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Restrict to the ArkMask repo only — prevents other repos from impersonating
  # the GitHub Actions service account even if they obtain a GitHub OIDC token.
  attribute_condition = "attribute.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow GitHub Actions tokens (for the ArkMask repo) to impersonate the SA.
# workloadIdentityUser: exchange OIDC token for federated credential.
# serviceAccountTokenCreator: generate OAuth2 access tokens (required for
# Artifact Registry auth via gcloud / docker login).
resource "google_service_account_iam_member" "github_wif" {
  count              = var.create_wif ? 1 : 0
  service_account_id = google_service_account.github[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github_repo}"
}

resource "google_service_account_iam_member" "github_token_creator" {
  count              = var.create_wif ? 1 : 0
  service_account_id = google_service_account.github[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github_repo}"
}

# ── GitHub Actions SA roles ───────────────────────────────────────────────────

# Deploy new revisions to Cloud Run.
resource "google_project_iam_member" "github_run_admin" {
  count   = var.create_wif ? 1 : 0
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.github[0].email}"
}

# Push Docker images to Artifact Registry.
resource "google_project_iam_member" "github_artifactregistry_writer" {
  count   = var.create_wif ? 1 : 0
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github[0].email}"
}

# Required when gcloud run deploy --service-account is used — GitHub SA must be
# able to act as the Cloud Run service accounts.
resource "google_project_iam_member" "github_sa_user" {
  count   = var.create_wif ? 1 : 0
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.github[0].email}"
}
