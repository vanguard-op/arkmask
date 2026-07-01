# project_id is injected by CI via TF_VAR_project_id (sourced from GCP_PROJECT_ID
# secret in GitHub Actions).
# db_password is injected via TF_VAR_db_password (sourced from TF_VAR_DB_PASSWORD_PROD secret).
#
# GitHub Actions authentication to GCP (WIF or SA key) is provisioned and owned
# outside of this Terraform config.
#
# For local runs, export them before running terraform:
#   export TF_VAR_project_id="your-gcp-project-id"
#   export TF_VAR_db_password="your-password"
