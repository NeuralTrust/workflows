# GCP isolated backup project

Use a **dedicated GCP project** for git backups, separate from `neuraltrust-app-prod` and other runtime projects. This limits blast radius if CI credentials leak and keeps backup data out of production IAM boundaries.

## Recommended layout

| Resource | Name (example) | Purpose |
|----------|----------------|---------|
| GCP project | `neuraltrust-git-backup` | Isolated backup boundary |
| GCS bucket | `nt-git-backups` | Dated bundles + manifests |
| SA (CI) | `github-backup-runner@…` | WIF-only; upload via Actions |
| SA (emergency) | `backup-emergency-reader@…` | Offline JSON key in team credential vault |

## 1. Create project

```bash
export PROJECT_ID=neuraltrust-git-backup
gcloud projects create "$PROJECT_ID" --name="NeuralTrust Git Backups"
gcloud billing projects link "$PROJECT_ID" --billing-account=BILLING_ACCOUNT_ID
```

## 2. Create bucket (Object Lock + 3-week lifecycle)

```bash
export BUCKET=nt-git-backups
export REGION=europe-west1
chmod +x docs/backup/gcp-bucket-setup.sh
./docs/backup/gcp-bucket-setup.sh
```

This enables:

- Uniform bucket-level access
- Public access prevention
- Versioning
- **Object Lock** retention (21 days minimum)
- Lifecycle delete after **21 days** → keeps ~3 weekly snapshots

## 3. CI service account (WIF, no JSON key)

```bash
export PROJECT_ID=neuraltrust-git-backup
export SA=github-backup-runner
export BUCKET=nt-git-backups

gcloud iam service-accounts create "$SA" \
  --project="$PROJECT_ID" \
  --display-name="GitHub Actions org backup"

# Object create + retention (not objectAdmin — cannot delete locked objects during retention)
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectCreator"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.legacyBucketWriter"
```

Configure **Workload Identity Federation** binding so only `NeuralTrust/workflows` on branch `main` can impersonate this SA. Store in GitHub secrets:

- `BACKUP_WIF_PROVIDER`
- `BACKUP_WIF_SERVICE_ACCOUNT`

**Do not** reuse `PROD_WIF_*`.

## 4. GitHub App (read-only)

Create an org GitHub App with:

- Repository permissions: **Contents** Read, **Metadata** Read
- Install on all org repositories

Store `BACKUP_APP_ID` and `BACKUP_APP_PRIVATE_KEY` in `NeuralTrust/workflows` secrets.

## 5. GitHub repo configuration

In `NeuralTrust/workflows`:

| Type | Name | Value |
|------|------|-------|
| Variable | `GCS_BUCKET` | `nt-git-backups` |
| Secret | `BACKUP_WIF_PROVIDER` | WIF provider resource name |
| Secret | `BACKUP_WIF_SERVICE_ACCOUNT` | `github-backup-runner@…` |
| Secret | `BACKUP_APP_ID` | App ID |
| Secret | `BACKUP_APP_PRIVATE_KEY` | PEM |
| Secret | `BACKUP_ALERT_WEBHOOK` | Slack/Teams URL (optional) |

## 6. Emergency restore SA (offline key)

See `create-emergency-restore-sa.sh` and `emergency-restore-procedure.md`. The JSON key lives in your **team credential vault** only — never in git.
