# ArkMask Infrastructure Setup

One-time steps to bootstrap Terraform remote state, Workload Identity Federation,
and GitHub secrets before CI/CD can run.

---

## Prerequisites

- `gcloud` CLI authenticated as a project owner
- `terraform` >= 1.9 installed locally
- GitHub repo admin access

---

## Step 1 — Set the Terraform state bucket name

The GCS backend bucket name must be a literal string in `backend.tf` — it cannot come
from a variable. Replace the placeholder in both env files before running `terraform init`:

```bash
# Find the two occurrences
grep -rn "REPLACE_ME" infra/terraform/envs/
```

Open both files and replace `REPLACE_ME_project-id-tfstate` with `{your-gcp-project-id}-tfstate`:

- `infra/terraform/envs/staging/backend.tf`
- `infra/terraform/envs/prod/backend.tf`

Everything else (`project_id`, `github_repo`, `db_password`) is injected at runtime via
environment variables — no other hardcoded values to change.

---

## Step 2 — Create the Terraform state bucket

```bash
PROJECT_ID="your-gcp-project-id"

gcloud storage buckets create gs://${PROJECT_ID}-tfstate \
  --location=europe-west1 \
  --uniform-bucket-level-access \
  --project=${PROJECT_ID}

# Enable versioning so you can recover from a corrupted state file.
gcloud storage buckets update gs://${PROJECT_ID}-tfstate --versioning
```

---

## Step 3 — Enable required GCP APIs

```bash
gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  cloudtasks.googleapis.com \
  vpcaccess.googleapis.com \
  servicenetworking.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  firebase.googleapis.com \
  firestore.googleapis.com \
  --project=${PROJECT_ID}
```

---

## Step 4 — Bootstrap prod Terraform (creates WIF)

Prod is applied first because it creates the Workload Identity Pool, the WIF provider,
and the GitHub Actions service account (`arkmask-github-actions`) — all project-scoped
resources that CI/CD depends on.

```bash
export TF_VAR_project_id="your-gcp-project-id"
export TF_VAR_github_repo="owner/arkmask"          # e.g. khidirahmad05/arkmask
export TF_VAR_db_password="choose-a-strong-password"

cd infra/terraform/envs/prod
terraform init
terraform apply
```

Note the two outputs — you'll need them for GitHub secrets in Step 6:

```
workload_identity_provider = "projects/.../providers/arkmask-github-provider"
github_sa_email            = "arkmask-github-actions@{project-id}.iam.gserviceaccount.com"
```

---

## Step 5 — Bootstrap staging Terraform

```bash
cd infra/terraform/envs/staging
terraform init
terraform apply
# (TF_VAR_* exports from Step 4 are still in your shell)
```

---

## Step 6 — Populate Secret Manager secrets

Terraform created the secret resources but not their values. Add the actual values now:

```bash
# ── Staging ──────────────────────────────────────────────────────────────────

DB_IP=$(terraform -chdir=infra/terraform/envs/staging output -raw db_private_ip)

# Database connection URL
echo -n "postgresql://arkmask:${TF_VAR_db_password}@${DB_IP}:5432/arkmask" | \
  gcloud secrets versions add staging-arkmask-db-url --data-file=-

# Firebase Admin SDK service account JSON (gitignored — provision separately per env)
gcloud secrets versions add staging-arkmask-firebase-credentials \
  --data-file=backend/arkmask-firebase.json

# Stripe test keys (from https://dashboard.stripe.com/test/apikeys)
echo -n "sk_test_..." | gcloud secrets versions add staging-arkmask-stripe-secret-key --data-file=-
echo -n "whsec_..."   | gcloud secrets versions add staging-arkmask-stripe-webhook-secret --data-file=-

# ── Prod ─────────────────────────────────────────────────────────────────────
# Repeat with prod- prefix and live keys.

DB_IP_PROD=$(terraform -chdir=infra/terraform/envs/prod output -raw db_private_ip)

echo -n "postgresql://arkmask:PROD_PASSWORD@${DB_IP_PROD}:5432/arkmask" | \
  gcloud secrets versions add prod-arkmask-db-url --data-file=-

gcloud secrets versions add prod-arkmask-firebase-credentials \
  --data-file=backend/arkmask-firebase.json   # use prod Firebase SA if separate

echo -n "sk_live_..." | gcloud secrets versions add prod-arkmask-stripe-secret-key --data-file=-
echo -n "whsec_..."   | gcloud secrets versions add prod-arkmask-stripe-webhook-secret --data-file=-
```

---

## Step 7 — Configure GitHub secrets and variables

In GitHub → **Settings → Secrets and variables → Actions**:

**Secrets:**

| Secret | Value |
|---|---|
| `GCP_WIF_PROVIDER` | `workload_identity_provider` output from Step 4 |
| `GCP_WIF_SA_EMAIL` | `github_sa_email` output from Step 4 |
| `GCP_PROJECT_ID` | Your GCP project ID |
| `TF_VAR_DB_PASSWORD` | Cloud SQL password (staging) |
| `TF_VAR_DB_PASSWORD_PROD` | Cloud SQL password (prod) |
| `STAGING_API_BASE_URL` | `api_url` output from staging terraform apply |
| `STRIPE_PUBLISHABLE_KEY_TEST` | Stripe test publishable key (for Flutter APK builds) |

**Variables (non-secret):**

| Variable | Value |
|---|---|
| `GCP_REGION` | `europe-west1` |
| `GITHUB_REPO` | `owner/arkmask` (e.g. `khidirahmad05/arkmask`) |

---

## Step 8 — Configure GitHub Environments

In GitHub → **Settings → Environments**:

- **staging** — no approval required; deploys automatically on merge to `main`
- **prod** — add yourself (or your team) as Required reviewers; every prod deploy needs manual approval

---

## Step 9 — Push to main and verify CI

Merge any change to `main` that touches `backend/` or `infra/terraform/` and watch the
Actions tab. The first run will:

1. Build and push the API Docker image to Artifact Registry
2. Deploy `staging-arkmask-api` to Cloud Run
3. Hit `{staging_url}/health` — make sure this endpoint exists in the FastAPI app
4. Wait for your approval before deploying to prod

---

## Day-to-day operations

| Task | Command |
|---|---|
| Plan staging locally | `cd infra/terraform/envs/staging && terraform plan` |
| Apply staging locally | `terraform apply` |
| Plan prod locally | `cd infra/terraform/envs/prod && terraform plan` |
| View API logs (staging) | `gcloud run services logs read staging-arkmask-api --region=europe-west1` |
| View API logs (prod) | `gcloud run services logs read prod-arkmask-api --region=europe-west1` |
| List Cloud Tasks queues | `gcloud tasks queues list --location=europe-west1` |
| Connect to Cloud SQL | `psql "host=PRIVATE_IP dbname=arkmask user=arkmask"` |
| Rotate a secret | `echo -n "new-value" \| gcloud secrets versions add SECRET_NAME --data-file=-` |
| Redeploy without code change | Re-run the Deploy workflow manually via `workflow_dispatch` |
