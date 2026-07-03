#!/usr/bin/env bash
# ==============================================================================
# Create read-only emergency restore service account + download JSON key
# ==============================================================================
# Run locally by a GCP admin. Store the key ONLY in 1Password (see procedure doc).
# NEVER commit the JSON file.
#
# Usage:
#   export PROJECT_ID=neuraltrust-git-backup
#   export BUCKET=nt-git-backups
#   ./create-emergency-restore-sa.sh /secure/path/backup-emergency-reader.json
# ==============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID}"
BUCKET="${BUCKET:?Set BUCKET}"
KEY_PATH="${1:?Usage: $0 /path/to/key.json}"
SA_NAME=backup-emergency-reader
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if [ -f "$KEY_PATH" ]; then
  echo "ERROR: Refusing to overwrite existing key at ${KEY_PATH}"
  exit 1
fi

gcloud iam service-accounts create "$SA_NAME" \
  --project="$PROJECT_ID" \
  --display-name="Emergency offline backup restore reader" 2>/dev/null || true

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectViewer"

gcloud iam service-accounts keys create "$KEY_PATH" \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID"

chmod 600 "$KEY_PATH"
echo "Key written to ${KEY_PATH}"
echo "Upload to 1Password and delete local copy after verification."
echo "Document restore steps in emergency-restore-procedure.md"
