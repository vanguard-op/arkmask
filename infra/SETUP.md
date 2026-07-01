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
from a variable. Open both env files and replace the placeholder with your actual bucket name:

- `infra/terraform/envs/staging/backend.tf`
- `infra/terraform/envs/prod/backend.tf`

```bash
# Confirm there are no remaining placeholders
grep -rn "REPLACE_ME" infra/terraform/envs/
```

Everything else (`project_id`, `github_repo`) is injected at runtime via
environment variables — no other hardcoded values to change.

---

## Step 2 — Create the Terraform state bucket

```bash
PROJECT_ID="your-gcp-project-id"

gcloud storage buckets create gs://arkmask-tfstate \
  --location=europe-west1 \
  --uniform-bucket-level-access \
  --project=${PROJECT_ID}

# Enable versioning so you can recover from a corrupted state file.
gcloud storage buckets update gs://arkmask-tfstate --versioning
```

---

## Step 3 — Enable required GCP APIs

```bash
gcloud services enable \
  run.googleapis.com \
  cloudtasks.googleapis.com \
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

> No VPC, Cloud SQL, or `vpcaccess.googleapis.com` needed — Firestore and GCS
> are reached over HTTPS directly from Cloud Run.

---

## Step 4 — Bootstrap prod Terraform (creates WIF)

Prod is applied first because it creates the Workload Identity Pool, the WIF provider,
and the GitHub Actions service account (`arkmask-github-actions`) — all project-scoped
resources that CI/CD depends on.

```bash
export TF_VAR_project_id="your-gcp-project-id"
export TF_VAR_github_repo="owner/arkmask"   # e.g. khidirahmad05/arkmask

cd infra/terraform/envs/prod
terraform init
terraform apply
```

Note the two outputs — you'll need them for GitHub secrets in Step 7:

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

## Step 6 — Populate the consolidated Secret Manager secret

Terraform created the secret resources but not their values. Each environment has a
**single JSON secret** (`{env}-arkmask-config`) that the backend reads at startup and
unpacks into individual environment variables.

Build the JSON payload and add it as a new secret version:

```bash
# ── Staging (test keys) ───────────────────────────────────────────────────────

cat > /tmp/staging-config.json <<'EOF'
{
  "stripe_secret_key":            "sk_test_...",
  "stripe_webhook_secret":        "whsec_...",
  "stripe_price_creator_monthly": "price_...",
  "stripe_price_creator_annual":  "price_...",
  "stripe_price_studio_monthly":  "price_...",
  "stripe_price_studio_annual":   "price_...",
  "firebase_credentials_path":    ""
}
EOF

gcloud secrets versions add staging-arkmask-config \
  --data-file=/tmp/staging-config.json \
  --project=${PROJECT_ID}

rm /tmp/staging-config.json   # don't leave secrets on disk

# ── Prod (live keys) ──────────────────────────────────────────────────────────

cat > /tmp/prod-config.json <<'EOF'
{
  "stripe_secret_key":            "sk_live_...",
  "stripe_webhook_secret":        "whsec_...",
  "stripe_price_creator_monthly": "price_...",
  "stripe_price_creator_annual":  "price_...",
  "stripe_price_studio_monthly":  "price_...",
  "stripe_price_studio_annual":   "price_...",
  "firebase_credentials_path":    ""
}
EOF

gcloud secrets versions add prod-arkmask-config \
  --data-file=/tmp/prod-config.json \
  --project=${PROJECT_ID}

rm /tmp/prod-config.json
```

> **Firebase credentials:** In Cloud Run the backend uses Application Default Credentials
> (ADC) automatically — leave `firebase_credentials_path` empty. The Cloud Run service
> account has `roles/datastore.user` and `roles/firebase.sdkAdminServiceAgent` bound by
> Terraform, so no key file is needed.

> **Rotating a value:** Add a new secret version and Cloud Run will pick it up on the next
> container start (or force a re-deploy):
> ```bash
> gcloud secrets versions add staging-arkmask-config --data-file=/tmp/new-config.json
> ```

---

## Step 7 — Configure GitHub secrets and variables

In GitHub → **Settings → Secrets and variables → Actions**:

**Secrets:**

| Secret | Value |
|---|---|
| `GCP_WIF_PROVIDER` | `workload_identity_provider` output from Step 4 |
| `GCP_WIF_SA_EMAIL` | `github_sa_email` output from Step 4 |
| `GCP_PROJECT_ID` | Your GCP project ID |
| `STAGING_API_BASE_URL` | `api_url` output from staging `terraform apply` |
| `STRIPE_PUBLISHABLE_KEY_TEST` | Stripe test publishable key (for Flutter APK builds) |

**Variables (non-secret):**

| Variable | Value |
|---|---|
| `GCP_REGION` | `europe-west1` |
| `GCP_GITHUB_REPO` | `owner/arkmask` (e.g. `khidirahmad05/arkmask`) |

> No `TF_VAR_DB_PASSWORD` — there is no database password. Firestore is the sole data store
> and is accessed via the service account's IAM binding, not a connection string.

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
3. Apply staging Terraform (Secret Manager secret must already have a version from Step 6)
4. Wait for your manual approval before deploying to prod

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
| Rotate a secret | `gcloud secrets versions add {env}-arkmask-config --data-file=/tmp/new-config.json` |
| Redeploy without code change | Re-run the Deploy workflow manually via `workflow_dispatch` |
| Force new Cloud Run revision | `gcloud run services update {env}-arkmask-api --region=europe-west1 --project=${PROJECT_ID}` |
