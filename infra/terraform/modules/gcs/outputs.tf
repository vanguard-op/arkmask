output "bucket_name" {
  description = "Name of the GCS media bucket."
  value       = google_storage_bucket.media.name
}

output "bucket_url" {
  description = "GCS URI of the media bucket (gs://...)."
  value       = google_storage_bucket.media.url
}
