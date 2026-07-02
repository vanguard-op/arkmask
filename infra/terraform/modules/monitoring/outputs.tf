output "notification_channel_id" {
  description = "The email notification channel ID, if var.alert_email was set (null otherwise)."
  value       = var.alert_email != "" ? google_monitoring_notification_channel.email[0].id : null
}
