# project_id and github_repo are injected by CI via TF_VAR_project_id and TF_VAR_github_repo
# (sourced from GCP_PROJECT_ID secret and GITHUB_REPO variable in GitHub Actions).
# db_password is injected via TF_VAR_db_password (sourced from TF_VAR_DB_PASSWORD_PROD secret).
#
# For local runs, export them before running terraform:
#   export TF_VAR_project_id="your-gcp-project-id"
#   export TF_VAR_github_repo="owner/arkmask"
#   export TF_VAR_db_password="your-password"
