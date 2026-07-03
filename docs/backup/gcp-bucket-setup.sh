#!/usr/bin/env bash
# ==============================================================================
# Create hardened GCS backup bucket (isolated GCP project)
# ==============================================================================
# Prerequisites:
#   - gcloud CLI authenticated as project admin
#   - Dedicated project (e.g. neuraltrust-git-backup) — see gcp-isolated-project.md
#
# Usage:
#   export PROJECT_ID=neuraltrust-git-backup
#   export BUCKET=nt-git-backups
#   export REGION=europe-west1
#   ./gcp-bucket-setup.sh
# ==============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID}"
BUCKET="${BUCKET:?Set BUCKET}"
REGION="${REGION:-europe-west1}"
RETENTION_DAYS="${RETENTION_DAYS:-21}"

echo "==> Enabling APIs in ${PROJECT_ID}"
gcloud services enable storage.googleapis.com iam.googleapis.com iamcredentials.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Creating bucket gs://${BUCKET}"
if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Bucket already exists — skipping create."
else
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --versioning
fi

echo "==> Enabling Object Lock (retention ${RETENTION_DAYS}d minimum)"
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --retention-period="${RETENTION_DAYS}d" \
  --lock-retention-period 2>/dev/null || \
  echo "WARN: retention period may already be locked — verify manually."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "==> Applying lifecycle (delete objects older than ${RETENTION_DAYS} days)"
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --lifecycle-file="${SCRIPT_DIR}/lifecycle-21d.json"

echo "==> Done. Next: create backup-runner SA + WIF binding (see gcp-isolated-project.md)"
