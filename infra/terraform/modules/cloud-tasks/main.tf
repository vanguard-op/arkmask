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
  name     = "${var.env}-arkmask-img-q"
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
  name     = "${var.env}-arkmask-vid-q"
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
  name     = "${var.env}-arkmask-mrg-q"
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
