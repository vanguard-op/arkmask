output "api_sa_email" {
  description = "Email of the API Cloud Run service account."
  value       = google_service_account.api.email
}

output "workers_sa_email" {
  description = "Email of the workers Cloud Run service account."
  value       = google_service_account.workers.email
}

output "github_sa_email" {
  description = "Email of the GitHub Actions service account (null if create_wif = false)."
  value       = var.create_wif ? google_service_account.github[0].email : null
}

output "workload_identity_provider" {
  description = "Full resource name of the WIF provider — used in GitHub Actions as workload_identity_provider. Null if create_wif = false."
  value       = var.create_wif ? google_iam_workload_identity_pool_provider.github[0].name : null
}
