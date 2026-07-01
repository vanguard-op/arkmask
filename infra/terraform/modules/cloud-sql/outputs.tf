output "instance_name" {
  description = "Cloud SQL instance name."
  value       = google_sql_database_instance.main.name
}

output "private_ip" {
  description = "Private IP address of the Cloud SQL instance (used in DATABASE_URL)."
  value       = google_sql_database_instance.main.private_ip_address
}

output "connection_name" {
  description = "Cloud SQL connection name (project:region:instance) — used with Cloud SQL Auth Proxy if needed."
  value       = google_sql_database_instance.main.connection_name
}
