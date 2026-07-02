# Monitoring module — alerting for the three failure modes documented in
# docs/ArkMask/architecture.md "Logging & Monitoring":
#   1. Cloud Run 5xx rate spike (API + workers)
#   2. Cloud Tasks queue backlog (best available proxy for "dead-letter
#      depth" — Cloud Tasks has no native DLQ concept like Pub/Sub; a
#      sustained backlog means tasks are failing/retrying faster than
#      they're being consumed)
#   3. Stripe webhook delivery failure (log-based metric on the
#      STRIPE_WEBHOOK_PROCESSING_FAILED marker logged by
#      backend/app/routers/billing.py)
#
# Alert policies are always created so incidents are visible in Cloud
# Monitoring even without a notification channel; set var.alert_email to
# actually get paged.

locals {
  # Human-readable prefix for this environment's alert display names.
  name_prefix = "[${var.env}] arkmask"
}

# ── Notification channel ──────────────────────────────────────────────────────

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "${local.name_prefix} — Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

locals {
  notification_channels = var.alert_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

# ── Cloud Run 5xx rate spike (API + workers) ──────────────────────────────────

resource "google_monitoring_alert_policy" "cloud_run_5xx" {
  for_each = toset([var.api_service_name, var.workers_service_name])

  project      = var.project_id
  display_name = "${local.name_prefix} — ${each.value} 5xx rate spike"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "5xx responses > 5 in 5 min"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "resource.label.service_name = \"${each.value}\"",
        "metric.type = \"run.googleapis.com/request_count\"",
        "metric.label.response_code_class = \"5xx\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notification_channels

  documentation {
    content   = "More than 5 5xx responses from ${each.value} in a 5-minute window. Check Cloud Run logs: gcloud logging read 'resource.labels.service_name=\"${each.value}\" AND severity>=ERROR'"
    mime_type = "text/markdown"
  }
}

# ── Cloud Tasks queue backlog ──────────────────────────────────────────────────

resource "google_monitoring_alert_policy" "cloud_tasks_backlog" {
  for_each = toset(var.cloud_tasks_queue_ids)

  project      = var.project_id
  display_name = "${local.name_prefix} — ${each.value} queue backlog"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Queue depth > 50 sustained for 10 min"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_tasks_queue\"",
        "resource.label.queue_id = \"${each.value}\"",
        "metric.type = \"cloudtasks.googleapis.com/queue/depth\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 50
      duration        = "600s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notification_channels

  documentation {
    content   = "Queue ${each.value} has had a backlog > 50 tasks for 10+ minutes — likely means the workers service is failing or falling behind. Check workers Cloud Run logs and the queue's dashboard in Cloud Tasks."
    mime_type = "text/markdown"
  }
}

# ── Stripe webhook processing failures (log-based metric) ─────────────────────

resource "google_logging_metric" "stripe_webhook_failures" {
  project     = var.project_id
  name        = "${var.env}_stripe_webhook_processing_failed"
  description = "Counts STRIPE_WEBHOOK_PROCESSING_FAILED errors logged by backend/app/routers/billing.py::stripe_webhook."
  filter      = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.api_service_name}\" AND textPayload:\"STRIPE_WEBHOOK_PROCESSING_FAILED\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "stripe_webhook_failure" {
  project      = var.project_id
  display_name = "${local.name_prefix} — Stripe webhook processing failure"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "Any webhook processing failure"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.stripe_webhook_failures.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notification_channels

  documentation {
    content   = "A Stripe webhook event failed to process (see STRIPE_WEBHOOK_PROCESSING_FAILED in ${var.api_service_name} logs). Stripe will retry automatically, but investigate — a persistent failure means subscription/tier state can drift out of sync with Stripe."
    mime_type = "text/markdown"
  }
}
