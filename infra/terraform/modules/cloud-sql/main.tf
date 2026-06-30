# Cloud SQL module — PostgreSQL 15 instance with private IP only.
#
# The instance is accessible exclusively through the VPC connector from Cloud Run.
# No public IP is assigned. Daily automated backups are enabled with 7-day retention,
# matching the architecture requirement (recovery target: within 1 hour of failure).

# Private services access — required for private IP Cloud SQL.
resource "google_compute_global_address" "private_ip_range" {
  name          = "${var.env}-arkmask-sql-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = var.vpc_id
  project       = var.project_id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = var.vpc_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

resource "google_sql_database_instance" "main" {
  name             = "${var.env}-arkmask-pg"
  database_version = "POSTGRES_15"
  region           = var.region
  project          = var.project_id

  # Prevent accidental destruction of production data.
  deletion_protection = var.deletion_protection

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = var.instance_tier

    ip_configuration {
      # Private IP only — Cloud Run accesses the instance via the VPC connector.
      ipv4_enabled    = false
      private_network = var.vpc_id

      # Allows GCP services (e.g. Cloud Run) to connect via private path
      # without going through the public internet.
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled    = true
      start_time = "02:00" # 2 AM UTC — off-peak for europe-west1

      backup_retention_settings {
        retained_backups = 7 # 7-day retention as per architecture spec
        retention_unit   = "COUNT"
      }

      # Point-in-time recovery via WAL archiving.
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }

    # Query insights — useful for catching slow query regressions.
    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = false
      record_client_address   = false
    }

    maintenance_window {
      day  = 7 # Sunday
      hour = 4 # 4 AM UTC
    }
  }
}

resource "google_sql_database" "arkmask" {
  name     = "arkmask"
  instance = google_sql_database_instance.main.name
  project  = var.project_id
}

resource "google_sql_user" "app" {
  name     = "arkmask"
  instance = google_sql_database_instance.main.name
  password = var.db_password
  project  = var.project_id
}
