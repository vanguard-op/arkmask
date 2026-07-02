# ArkMask Infrastructure Setup

One-time steps to bootstrap Terraform remote state and GitHub secrets before
CI/CD can run.

> **Note:** GitHub Actions authentication to GCP (Workload Identity Federation
> or a service account key) is provisioned and owned outside of this
> Terraform config. This project's Terraform only manages resources needed
> to run the app itself (service accounts for Cloud Run, IAM bindings for
> those service accounts, storage, queues, etc). Set up your own WIF pool /
> SA key and populate the GitHub secrets in Step 7 accordingly.

---

## Prerequisites

- `gcloud` CLI authenticated as a project owner
- `terraform` >= 1.9 installed locally
- GitHub repo admin access
- GitHub Actions → GCP authentication (WIF or SA key) already set up by you

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

Everything else (`project_id`) is injected at runtime via environment
variables — no other hardcoded values to change.

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

## Step 4 — Bootstrap prod Terraform

```bash
export TF_VAR_project_id="your-gcp-project-id"

cd infra/terraform/envs/prod
terraform init
terraform apply
```

---

## Step 5 — Bootstrap staging Terraform

```bash
cd infra/terraform/envs/staging
terraform init
terraform apply
# (TF_VAR_project_id export from Step 4 is still in your shell)
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

> **Billing redirect URLs:** `stripe_billing_success_url`, `stripe_billing_cancel_url`, and
> `stripe_billing_portal_return_url` default to `arkmask://billing-return?status=...` (see
> `backend/app/config.py`) — the app's own custom URL scheme, not a hosted web page. ArkMask
> has no marketing/web presence to redirect to, and Stripe Checkout/Portal is opened in the
> system browser (`LaunchMode.externalApplication`, not an in-app WebView — required by
> Stripe's mobile guidance), so a plain `https://` URL can't hand control back to the app even
> if one existed. Leave these three keys **out** of the JSON secret entirely so the code
> defaults apply — only set them if you have a real reason to override (e.g. testing against a
> different deep-link scheme).

---

## Step 6b — Set up the Stripe webhook

`POST /billing/webhook` (see `backend/app/routers/billing.py`) must be registered as an
endpoint in the Stripe Dashboard (or via the Stripe CLI for local dev) pointing at your
**actual deployed Cloud Run URL** — not `localhost`, and not a URL the Stripe CLI generates for
local port-forwarding. If the endpoint is missing, misconfigured, or the webhook secret in the
config JSON (Step 6) doesn't match the endpoint's own signing secret, Stripe will never notify
the backend of a completed checkout — the user's payment succeeds on Stripe's side but their
`tier`/`credit_balance` never updates in Firestore, no matter how long they wait or how many
times they restart the app.

**1. Get your Cloud Run API URL:**

```bash
# Staging
terraform -chdir=infra/terraform/envs/staging output api_url

# Prod
terraform -chdir=infra/terraform/envs/prod output api_url
```

This is the `api_url` Terraform output from Step 5 (staging) / the prod equivalent — something
like `https://staging-arkmask-api-xxxxxxxxxx-ew.a.run.app`. The webhook URL is that base URL
plus `/billing/webhook`.

**2. Create the webhook endpoint in the Stripe Dashboard** (recommended for staging/prod —
persists independently of any local terminal session, unlike the CLI method below):

1. Go to **Stripe Dashboard → Developers → Webhooks → Add endpoint**.
2. Make sure you're in the right mode (**Test mode** for staging/test keys, **Live mode** for
   prod/live keys — the toggle is top-right of the Dashboard).
3. Endpoint URL: `https://<your-cloud-run-url>/billing/webhook`.
4. Select events to listen for: `customer.subscription.created`,
   `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`,
   `invoice.payment_failed` (see the handler list at the top of `billing.py`).
5. Click **Add endpoint**, then open it and click **Reveal** under "Signing secret" — this is
   your `whsec_...` value.
6. Put that value in `stripe_webhook_secret` in the JSON secret for the matching environment
   (Step 6) and run the `gcloud secrets versions add` command again. Cloud Run picks it up on
   the next container start — either wait for a natural restart or force one:
   ```bash
   gcloud run services update staging-arkmask-api --region=europe-west1 --project=${PROJECT_ID}
   ```

**3. Alternative — Stripe CLI, for local `uvicorn` development only:**

```bash
stripe listen --forward-to localhost:8000/billing/webhook
```

This prints a `whsec_...` secret **scoped to that CLI session** — it is a different value every
time you run the command, and it only works while `stripe listen` keeps running in that
terminal. **Never put a `stripe listen` secret in the staging/prod config JSON** — it does not
correspond to any real endpoint Stripe will actually deliver events to over the internet, so
webhooks silently never arrive (this is the most common cause of "I paid but my tier never
updated" in a deployed environment). Use the Dashboard method above for anything other than a
local `uvicorn` process on your own machine.

**4. Verify delivery:** In the Dashboard, open the endpoint and check the **Events** tab after a
test purchase (use a [Stripe test card](https://docs.stripe.com/testing) in test mode) — you
should see the event listed with a `200` response. If you see a non-200 response or no event at
all, check `gcloud run services logs read {env}-arkmask-api --region=europe-west1` for
`STRIPE_WEBHOOK_PROCESSING_FAILED` or a signature-verification warning.

---

## Step 7 — Configure GitHub secrets and variables

In GitHub → **Settings → Secrets and variables → Actions**:

**Secrets:**

| Secret | Value |
|---|---|
| `GCP_WIF_PROVIDER` / `GCP_CREDENTIALS` | Your own WIF provider or SA key, set up outside this Terraform config |
| `GCP_PROJECT_ID` | Your GCP project ID |
| `STAGING_API_BASE_URL` | `api_url` output from staging `terraform apply` |
| `STRIPE_PUBLISHABLE_KEY_TEST` | Stripe test publishable key (for Flutter APK builds) |

**Variables (non-secret):**

| Variable | Value |
|---|---|
| `GCP_REGION` | `europe-west1` |

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
