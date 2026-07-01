output "api_sa_email" {
  description = "Email of the API Cloud Run service account."
  value       = google_service_account.api.email
}

output "workers_sa_email" {
  description = "Email of the workers Cloud Run service account."
  value       = google_service_account.workers.email
}
