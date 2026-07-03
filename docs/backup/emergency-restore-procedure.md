# Emergency restore procedure (offline credentials)

**Classification:** Internal — credentials live in an **encrypted `.dmg`** on macOS; the password is in **Apple Passwords** (shared secure note, 2+ responders).

## Vault layout (canonical)

Create once with `create-emergency-restore-vault.sh`:

```
neuraltrust-git-backup-vault.dmg   (AES-256 encrypted)
└── NeuralTrust Git Backup/
    ├── backup-emergency-reader.json
    ├── emergency-restore-procedure.md
    └── README.txt
```

| What | Where |
|------|--------|
| `.dmg` file | FileVault Mac + restricted team share (not git/Slack/email) |
| `.dmg` password | Apple Passwords → shared note `NeuralTrust Git Backup Vault` |
| Responders | Minimum **2 people** must know how to open Apple Passwords + mount the `.dmg` |

## When to use

- GitHub and/or GCP production access is unavailable (incident, lockout, ransomware).
- You need source code from a **known-good weekly snapshot** (use an older date if the latest week may be compromised).

## Prerequisites

1. Trusted Mac with FileVault enabled.
2. `gcloud` CLI installed.
3. Access to the `.dmg` and its password (Apple Passwords).
4. Network access to `storage.googleapis.com`.

## 1. Mount vault and authenticate

```bash
# Password from Apple Passwords shared note
hdiutil attach ~/Secure/neuraltrust-git-backup-vault.dmg
export VAULT="/Volumes/NeuralTrust Git Backup"
export GOOGLE_APPLICATION_CREDENTIALS="${VAULT}/backup-emergency-reader.json"
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
gcloud config set project neuraltrust-git-backup
```

## 2. List backup dates (last ~3 weeks)

```bash
gcloud storage ls gs://nt-git-backups/git-backups/ | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}/'
```

If you suspect compromise, pick the **oldest clean week** within retention — not necessarily the latest.

## 3. Download manifest and check anomalies

```bash
export BACKUP_DATE=2026-06-23
mkdir -p "./restore/${BACKUP_DATE}"
gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/manifest.json" \
  "./restore/${BACKUP_DATE}/"
jq '.anomalies, .repo_count, .repositories[] | select(.repo=="watchdog")' \
  "./restore/${BACKUP_DATE}/manifest.json"
```

Prefer a date with **empty `anomalies`** and expected `repo_count`.

## 4. Restore one repository

```bash
export REPO=watchdog
gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/${REPO}.bundle" \
  "./restore/${BACKUP_DATE}/"
gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/${REPO}.bundle.sha256" \
  "./restore/${BACKUP_DATE}/"
cd "./restore/${BACKUP_DATE}"
sha256sum -c "${REPO}.bundle.sha256"
git clone "${REPO}.bundle" "${REPO}-restored"
```

## 5. Bulk restore

```bash
mkdir -p "./restore/${BACKUP_DATE}/bundles" "./restore/${BACKUP_DATE}/out"
gcloud storage cp "gs://nt-git-backups/git-backups/${BACKUP_DATE}/*.bundle" \
  "./restore/${BACKUP_DATE}/bundles/"
for bundle in "./restore/${BACKUP_DATE}/bundles"/*.bundle; do
  name="$(basename "$bundle" .bundle)"
  git clone "$bundle" "./restore/${BACKUP_DATE}/out/${name}"
done
```

## 6. Post-restore

1. Verify `sha256` / `commit_count` against `manifest.json`.
2. Push to a **new** org or isolated fork before re-trusting production.
3. Rotate all secrets that may have lived in git history.
4. Unmount vault: `hdiutil detach "/Volumes/NeuralTrust Git Backup"`.
5. If the workstation was exposed, rotate the emergency SA key and rebuild the `.dmg`.

## What this does NOT restore

- GitHub Actions / Environment secrets
- Deploy keys (private halves)
- Git LFS objects
- Issues, PRs, wiki (unless in git)

## Key rotation and new vault

```bash
gcloud iam service-accounts keys list \
  --iam-account=backup-emergency-reader@neuraltrust-git-backup.iam.gserviceaccount.com
gcloud iam service-accounts keys delete KEY_ID \
  --iam-account=backup-emergency-reader@neuraltrust-git-backup.iam.gserviceaccount.com
export PROJECT_ID=neuraltrust-git-backup BUCKET=nt-git-backups
./create-emergency-restore-vault.sh ~/Secure/neuraltrust-git-backup-vault-$(date +%Y%m%d).dmg
# Update Apple Passwords note; destroy old .dmg securely
```
