output "vpc_id" {
  description = "Self-link of the VPC network."
  value       = google_compute_network.vpc.self_link
}

output "subnet_name" {
  description = "Name of the VPC subnet."
  value       = google_compute_subnetwork.subnet.name
}

output "connector_id" {
  description = "Self-link of the serverless VPC connector (used by Cloud Run)."
  value       = google_vpc_access_connector.connector.id
}
