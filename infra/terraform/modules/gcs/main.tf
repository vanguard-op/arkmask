# GCS module — permanent per-user media bucket.
#
# Objects under arkmask-media/{uid}/{project-slug}/ are permanent until the user
# explicitly deletes a project. No lifecycle deletion rule is applied.
# Workers write to this bucket; the Flutter app reads via presigned URLs issued by
# the API. Direct device ↔ GCS transfer never occurs.

resource "google_storage_bucket" "media" {
  name          = var.bucket_name
  location      = var.region
  project       = var.project_id
  force_destroy = var.force_destroy

  # Uniform bucket-level access — IAM only, no per-object ACLs.
  uniform_bucket_level_access = true

  # Versioning off — objects are immutable by convention (workers always write
  # to deterministic paths; overwrites replace the previous generation directly).
  versioning {
    enabled = false
  }

  # CORS for presigned URL fetch from Flutter WebView / in-app browser.
  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type", "Content-Length", "Accept-Ranges"]
    max_age_seconds = 3600
  }
}
