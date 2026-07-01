# IAM module — service accounts and role bindings for the app's own runtime needs.
#
# Two service accounts:
#   arkmask-api-sa      — runs the Cloud Run API service
#   arkmask-workers-sa  — runs the Cloud Run workers service (image/video/merge)
#
# GitHub Actions authentication (WIF or SA key) is managed outside of this
# project's Terraform — provisioned and owned separately.

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
