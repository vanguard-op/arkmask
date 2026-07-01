# Networking module — VPC, subnet, and serverless VPC connector.
#
# Cloud Run services connect to the private Cloud SQL instance via the
# VPC connector. All inter-service traffic stays on private IPs; Cloud SQL
# has no public IP endpoint.

resource "google_compute_network" "vpc" {
  name                    = "${var.env}-arkmask-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.env}-arkmask-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
  project       = var.project_id
}

# Serverless VPC connector — lets Cloud Run (API + workers) reach the private
# Cloud SQL instance and other private GCP services without leaving the VPC.
resource "google_vpc_access_connector" "connector" {
  name    = "${var.env}-arkmask-conn"
  region  = var.region
  project = var.project_id

  subnet {
    name = google_compute_subnetwork.subnet.name
  }

  machine_type  = var.connector_machine_type
  min_instances = 2
  max_instances = var.connector_max_instances
}
