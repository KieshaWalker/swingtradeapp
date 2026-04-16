#!/usr/bin/env bash
# =============================================================================
# deploy.sh — First-time GCP setup + manual deploy for options-trader-493420
# =============================================================================
# Run once to provision resources, then use Cloud Build triggers for CI/CD.
#
# Prerequisites:
#   gcloud auth login
#   gcloud config set project options-trader-493420
# =============================================================================

set -euo pipefail

PROJECT_ID="options-trader-493420"
REGION="us-central1"
SERVICE="swing-options-api"
ARTIFACT_REPO="swing-options-api"
SCHEDULER_SA="cloud-scheduler-invoker"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${SERVICE}:latest"

# ── Enable required APIs ───────────────────────────────────────────────────────
echo "Enabling APIs..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  --project="${PROJECT_ID}"

# ── Artifact Registry repo ────────────────────────────────────────────────────
echo "Creating Artifact Registry repo (skip if exists)..."
gcloud artifacts repositories create "${ARTIFACT_REPO}" \
  --repository-format=docker \
  --location="${REGION}" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "  repo already exists"

# ── Store secrets in Secret Manager ──────────────────────────────────────────
# Populate these values before running. Existing secrets are skipped.
store_secret() {
  local name=$1 value=$2
  if gcloud secrets describe "${name}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  secret ${name} already exists — skipping"
  else
    echo -n "${value}" | gcloud secrets create "${name}" \
      --data-file=- \
      --project="${PROJECT_ID}"
    echo "  created secret ${name}"
  fi
}

# ── Build & push image via Cloud Build ───────────────────────────────────────
# Use a short git SHA as the image tag so each build is uniquely addressable.
# Falls back to a timestamp if git isn't available.
TAG=$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)
echo "Building image with Cloud Build (tag: ${TAG})..."
gcloud builds submit \
  --config=api/cloudbuild.yaml \
  --substitutions="_REGION=${REGION},_SERVICE=${SERVICE},_ARTIFACT_REPO=${ARTIFACT_REPO},_TAG=${TAG}" \
  --project="${PROJECT_ID}" \
  .

# ── Service account for Cloud Scheduler ──────────────────────────────────────
echo "Creating scheduler service account..."
gcloud iam service-accounts create "${SCHEDULER_SA}" \
  --display-name="Cloud Scheduler Invoker" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "  SA already exists"

SA_EMAIL="${SCHEDULER_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud run services add-iam-policy-binding "${SERVICE}" \
  --region="${REGION}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}"

# ── Fetch Cloud Run service URL ───────────────────────────────────────────────
SERVICE_URL=$(gcloud run services describe "${SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo "Service URL: ${SERVICE_URL}"

# ── Cloud Scheduler job (8-hour Schwab pull) ──────────────────────────────────
echo "Creating Cloud Scheduler job..."
gcloud scheduler jobs create http schwab-pull-8h \
  --location="${REGION}" \
  --schedule="0 */8 * * *" \
  --uri="${SERVICE_URL}/jobs/schwab-pull" \
  --http-method=POST \
  --oidc-service-account-email="${SA_EMAIL}" \
  --oidc-token-audience="${SERVICE_URL}" \
  --time-zone="UTC" \
  --description="Pull Schwab data every 8 hours and run full math pipeline" \
  --project="${PROJECT_ID}" 2>/dev/null || \
gcloud scheduler jobs update http schwab-pull-8h \
  --location="${REGION}" \
  --schedule="0 */8 * * *" \
  --uri="${SERVICE_URL}/jobs/schwab-pull" \
  --http-method=POST \
  --oidc-service-account-email="${SA_EMAIL}" \
  --oidc-token-audience="${SERVICE_URL}" \
  --time-zone="UTC" \
  --project="${PROJECT_ID}"

echo ""
echo "Done. Resources in project ${PROJECT_ID}:"
echo "  Cloud Run:       ${SERVICE_URL}"
echo "  Scheduler job:   schwab-pull-8h (0 */8 * * * UTC)"
echo ""
echo "To trigger manually:"
echo "  gcloud scheduler jobs run schwab-pull-8h --location=${REGION} --project=${PROJECT_ID}"
