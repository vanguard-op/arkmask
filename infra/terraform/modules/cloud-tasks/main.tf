# Cloud Tasks module — three independent queues for image, video, and merge jobs.
#
# Separate queues per job type allow each to scale independently:
#   - image-queue: high concurrency, short jobs (10–60 s)
#   - video-queue: lower concurrency, long jobs (2–10 min)
#   - merge-queue: lowest concurrency, CPU-bound FFmpeg jobs
#
# Workers are invoked by Cloud Tasks using an OIDC token; the token SA is
# configured in the API code when tasks are enqueued (not here).

resource "google_cloud_tasks_queue" "image" {
  # Note: suffixed "-v2" because the original "-img-q" name was deleted during
  # earlier setup and GCP enforces a cooldown period before a queue name can
  # be reused, even after it no longer appears in listings.
  name     = "${var.env}-arkmask-img-q-v2"
  location = var.region
  project  = var.project_id

  rate_limits {
    max_concurrent_dispatches = var.image_queue_concurrency
    max_dispatches_per_second = 10
  }

  retry_config {
    max_attempts  = 5
    min_backoff   = "10s"
    max_backoff   = "300s"
    max_doublings = 4
  }
}

resource "google_cloud_tasks_queue" "video" {
  # See "-v2" note on the image queue above — same cooldown issue applies.
  name     = "${var.env}-arkmask-vid-q-v2"
  location = var.region
  project  = var.project_id

  rate_limits {
    max_concurrent_dispatches = var.video_queue_concurrency
    max_dispatches_per_second = 5
  }

  retry_config {
    # Fewer retries for video — failures are often provider-side and a third
    # retry rarely succeeds; better to surface the error to the user quickly.
    max_attempts  = 3
    min_backoff   = "30s"
    max_backoff   = "600s"
    max_doublings = 3
  }
}

resource "google_cloud_tasks_queue" "merge" {
  # See "-v2" note on the image queue above — same cooldown issue applies.
  name     = "${var.env}-arkmask-mrg-q-v2"
  location = var.region
  project  = var.project_id

  rate_limits {
    max_concurrent_dispatches = var.merge_queue_concurrency
    max_dispatches_per_second = 2
  }

  retry_config {
    max_attempts  = 3
    min_backoff   = "30s"
    max_backoff   = "600s"
    max_doublings = 3
  }
}
