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

# Allow unauthenticated browser access (Flutter web app calls the API directly)
gcloud run services add-iam-policy-binding "${SERVICE}" \
  --region="${REGION}" \
  --member="allUsers" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}"

# ── Fetch Cloud Run service URL ───────────────────────────────────────────────
SERVICE_URL=$(gcloud run services describe "${SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo "Service URL: ${SERVICE_URL}"

# ── Helper: create-or-update a scheduler job ──────────────────────────────────
upsert_job() {
  local name=$1; shift
  gcloud scheduler jobs create http "${name}" "$@" \
    --project="${PROJECT_ID}" 2>/dev/null || \
  gcloud scheduler jobs update http "${name}" "$@" \
    --project="${PROJECT_ID}"
}

COMMON_FLAGS=(
  --location="${REGION}"
  --http-method=POST
  --oidc-service-account-email="${SA_EMAIL}"
  --oidc-token-audience="${SERVICE_URL}"
  --time-zone="UTC"
)

echo "Creating/updating Cloud Scheduler jobs..."

# Job 1 — vol surface (all downstream jobs depend on this)
upsert_job vol-surface-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="0 13-21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/vol-surface-pull" \
  --attempt-deadline=1800s \
  --description="Fetch Schwab options chains → vol_surface_snapshots (Mon-Fri hourly, 13-21 UTC)"

# Job 2 — SABR calibration
upsert_job sabr-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="3 13-21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/sabr-pull" \
  --attempt-deadline=900s \
  --description="SABR calibration from vol surface snapshots (Mon-Fri hourly, 13-21 UTC)"

# Job 3a — Heston calibration batch 1 (first half of tickers, alphabetically)
upsert_job heston-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="6 13-21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/heston-pull?batch=1" \
  --attempt-deadline=1800s \
  --description="Heston calibration batch 1 (Mon-Fri hourly, 13-21 UTC)"

# Job 3b — Heston calibration batch 2 (second half of tickers, alphabetically)
upsert_job heston-pull-2 \
  "${COMMON_FLAGS[@]}" \
  --schedule="20 13-21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/heston-pull?batch=2" \
  --attempt-deadline=1800s \
  --description="Heston calibration batch 2 (Mon-Fri hourly, 13-21 UTC)"

# Job 4 — IV analytics
upsert_job iv-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="9 13-21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/iv-pull" \
  --attempt-deadline=900s \
  --description="IV analytics + vvol rank → iv_snapshots (Mon-Fri hourly, 13-21 UTC)"

# Job 5 — Greek grid
upsert_job greek-grid-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="12 13-21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/greek-grid-pull" \
  --attempt-deadline=900s \
  --description="Greek grid aggregation → greek_grid_snapshots (Mon-Fri hourly, 13-21 UTC)"

# Job 6 — DEPRECATED: greek_snapshots are now written by greek-grid-pull from
# its single chain fetch. Remove the old scheduler job if it still exists.
gcloud scheduler jobs delete greek-snapshots-pull \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null || echo "  greek-snapshots-pull job already removed"

# Job 7 — Regime classification
upsert_job regime-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="18 13-21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/regime-pull" \
  --attempt-deadline=900s \
  --description="Regime classification → regime_snapshots (Mon-Fri hourly, 13-21 UTC)"

# Job ML — Regime ML retrain (weekly, after enough history accumulates)
upsert_job regime-train-weekly \
  "${COMMON_FLAGS[@]}" \
  --schedule="0 0 * * 0" \
  --uri="${SERVICE_URL}/jobs/regime-train" \
  --attempt-deadline=600s \
  --description="Weekly regime ML retrain — logistic on 180d of regime_snapshots (Sunday 00:00 UTC)"

# Job 10 — Position EOD snapshot (must run after market close)
upsert_job position-eod-snapshot \
  "${COMMON_FLAGS[@]}" \
  --schedule="5 21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/position-eod-snapshot" \
  --attempt-deadline=600s \
  --description="EOD Greeks + fair-value snapshot for all open position legs (Mon-Fri 21:05 UTC)"

# Job 9 — Expected move (EOD)
upsert_job expected-move-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="0 21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/expected-move-pull" \
  --attempt-deadline=900s \
  --description="EOD expected move bands → expected_move_snapshots (Mon-Fri 9 PM UTC)"

# Job 11 — Crisis checklist (EOD, market-level)
upsert_job crisis-pull \
  "${COMMON_FLAGS[@]}" \
  --schedule="10 21 * * 1-5" \
  --uri="${SERVICE_URL}/jobs/crisis-pull" \
  --attempt-deadline=600s \
  --description="Market-level crisis-signal checklist → crisis_checklist_snapshots (Mon-Fri 21:10 UTC)"

# Job 8a — Weekly vol period snapshot
upsert_job vol-period-weekly \
  "${COMMON_FLAGS[@]}" \
  --schedule="0 22 * * 5" \
  --uri="${SERVICE_URL}/jobs/vol-period-weekly" \
  --attempt-deadline=600s \
  --description="Weekly vol period snapshot (Fridays 10 PM UTC)"

# Job 8b — Monthly vol period snapshot
upsert_job vol-period-monthly \
  "${COMMON_FLAGS[@]}" \
  --schedule="0 22 1 * *" \
  --uri="${SERVICE_URL}/jobs/vol-period-monthly" \
  --attempt-deadline=600s \
  --description="Monthly vol period snapshot (1st of month 10 PM UTC)"

echo ""
echo "Done. Resources in project ${PROJECT_ID}:"
echo "  Cloud Run:  ${SERVICE_URL}"
echo "  Scheduler:  vol-surface-pull, sabr-pull, heston-pull, heston-pull-2, iv-pull,"
echo "              greek-grid-pull (also writes greek_snapshots), regime-pull,"
echo "              expected-move-pull, position-eod-snapshot,"
echo "              vol-period-weekly, vol-period-monthly, regime-train-weekly"
echo ""
echo "Manual triggers:"
echo "  gcloud scheduler jobs run <job-name> --location=${REGION} --project=${PROJECT_ID}"
