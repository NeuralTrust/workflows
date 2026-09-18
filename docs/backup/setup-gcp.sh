#!/usr/bin/env bash
# ==============================================================================
# One-shot GCP setup for the org backup.
# ==============================================================================
# Creates: an isolated project, a hardened bucket, a service account that can
# WRITE but never DELETE, and Workload Identity Federation so GitHub Actions
# authenticates with no JSON key.
#
# Safe to re-run: every step skips itself if the thing already exists.
#
# Usage:
#   export BILLING_ACCOUNT=0X0X0X-0X0X0X-0X0X0X   # gcloud billing accounts list
#   ./docs/backup/setup-gcp.sh
#
# At the end it prints the exact values to paste into GitHub.
# ==============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neuraltrust-backup}"
BUCKET="${BUCKET:-neuraltrust-git-backup}"
REGION="${REGION:-europe-west1}"
RETENTION_DAYS="${RETENTION_DAYS:-180}"
GITHUB_ORG="${GITHUB_ORG:-NeuralTrust}"
GITHUB_REPO="${GITHUB_REPO:-workflows}"

# People who can read the backups. If only one person can reach the bucket, the
# backup has a single point of failure, and that person is on holiday the day it
# matters. Read access cannot delete anything.
READERS="${READERS:-victor.garcia@neuraltrust.ai,kadu.barral@neuraltrust.ai,telm.olivella@neuraltrust.ai}"

SA_NAME="backup-runner"
POOL="github-backup"
PROVIDER="github"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

# ------------------------------------------------------------------------------
say "1/7  Project ${PROJECT_ID}"
# ------------------------------------------------------------------------------
# A separate project is the whole point: if the production GCP project is
# compromised, the backups are in a different blast radius.
if gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Project already exists — skipping."
else
  : "${BILLING_ACCOUNT:?Set BILLING_ACCOUNT (see: gcloud billing accounts list)}"
  gcloud projects create "${PROJECT_ID}" --name="NeuralTrust Git Backup"
  gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT}"
fi

gcloud services enable \
  storage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project="${PROJECT_ID}"

# ------------------------------------------------------------------------------
say "2/7  Bucket gs://${BUCKET}"
# ------------------------------------------------------------------------------
# versioning                    -> an overwrite keeps the previous copy
# uniform-bucket-level-access   -> IAM only, no per-object ACL surprises
# public-access-prevention      -> can never be made public by accident
if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Bucket already exists — skipping create."
else
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --versioning
fi

# ------------------------------------------------------------------------------
say "3/7  Retention: delete snapshots older than ${RETENTION_DAYS} days"
# ------------------------------------------------------------------------------
# NOT using a locked bucket retention period: locking is irreversible and you
# can never shorten it again. A lifecycle rule does the job and stays editable.
#
# Note how the two rules interact: with versioning on, the first one does not
# erase bytes, it makes the object noncurrent. The second is what finally
# removes it 30 days later, so a snapshot occupies storage for up to
# RETENTION_DAYS + 30 days.
# ~0.65 GB per snapshot x ~30 snapshots on disk = ~20 GB = ~$0.40/month.
lifecycle_file="$(mktemp)"
trap 'rm -f "${lifecycle_file}"' EXIT
cat > "${lifecycle_file}" <<JSON
{
  "rule": [
    {
      "action": { "type": "Delete" },
      "condition": { "age": ${RETENTION_DAYS}, "matchesPrefix": ["git-backups/"] }
    },
    {
      "action": { "type": "Delete" },
      "condition": { "daysSinceNoncurrentTime": 30, "matchesPrefix": ["git-backups/"] }
    }
  ]
}
JSON
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --lifecycle-file="${lifecycle_file}"

# ------------------------------------------------------------------------------
say "4/7  Service account (write-only)"
# ------------------------------------------------------------------------------
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Service account already exists — skipping create."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="GitHub Actions org backup"
fi

# THE important bit: objectCreator can add objects but has NO delete permission.
# Combined with versioning, a stolen CI credential cannot destroy past backups —
# the worst it can do is add a new version on top. This replaces Object Lock.
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectCreator"

# Read access so the watchdog can list snapshots. Read cannot delete.
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectViewer"

# ------------------------------------------------------------------------------
say "5/7  Humans who can read the backups"
# ------------------------------------------------------------------------------
IFS=',' read -r -a reader_list <<< "${READERS}"
for reader in "${reader_list[@]}"; do
  reader="$(printf '%s' "${reader}" | tr -d '[:space:]')"
  [ -z "${reader}" ] && continue
  echo "  ${reader} -> roles/storage.objectViewer"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="user:${reader}" \
    --role="roles/storage.objectViewer" \
    --condition=None \
    --quiet >/dev/null
done

# ------------------------------------------------------------------------------
say "6/7  Workload Identity Federation (no JSON keys)"
# ------------------------------------------------------------------------------
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

if gcloud iam workload-identity-pools describe "${POOL}" \
     --project="${PROJECT_ID}" --location=global >/dev/null 2>&1; then
  echo "Pool already exists — skipping."
else
  gcloud iam workload-identity-pools create "${POOL}" \
    --project="${PROJECT_ID}" --location=global \
    --display-name="GitHub backup"
fi

if gcloud iam workload-identity-pools providers describe "${PROVIDER}" \
     --project="${PROJECT_ID}" --location=global \
     --workload-identity-pool="${POOL}" >/dev/null 2>&1; then
  echo "Provider already exists — skipping."
else
  # attribute-condition is mandatory for the GitHub issuer: without it, a
  # workflow in ANY GitHub org on the internet could request a token.
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER}" \
    --project="${PROJECT_ID}" --location=global \
    --workload-identity-pool="${POOL}" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'"
fi

# Only ${GITHUB_ORG}/${GITHUB_REPO} may impersonate the service account.
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}"

# ------------------------------------------------------------------------------
say "7/7  Done — paste these into GitHub"
# ------------------------------------------------------------------------------
cat <<OUT

  https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/settings/secrets/actions

  Secret  BACKUP_WIF_PROVIDER
          projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}

  Secret  BACKUP_WIF_SERVICE_ACCOUNT
          ${SA_EMAIL}

  https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/settings/variables/actions

  Variable  BACKUP_GCS_BUCKET
            ${BUCKET}

Still needed: the read-only GitHub App (BACKUP_APP_ID + BACKUP_APP_PRIVATE_KEY).
See docs/backup/README.md, step 2.

OUT
