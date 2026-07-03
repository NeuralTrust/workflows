# Emergency restore procedure (offline credentials)

**Classification:** Internal — store alongside the emergency SA JSON key in your **company credential vault** (see below).

## When to use

- GitHub and/or GCP production access is unavailable (incident, lockout, ransomware).
- You need to restore source code from the last known-good weekly backup.

## Prerequisites (pre-staged offline)

Store these in a **team-accessible, encrypted credential store** — any corporate password manager or secure vault works. Examples:

| Option | JSON key file | Procedure text |
|--------|---------------|----------------|
| **Apple Passwords** (macOS) | Secure note with pasted key *or* reference to FileVault-encrypted file path | Secure note / shared folder in iCloud (restricted) |
| **Bitwarden / Vaultwarden** | Secure attachment | Secure note |
| **Encrypted disk image** (`.dmg`) on Mac | File inside the image | Markdown/PDF in the same image |

Minimum bar: **two people** can access it in an emergency; **not** in git, Slack, or email.

1. **Vault entry:** `NeuralTrust Git Backup — Emergency SA`
   - Attachment or secure note: `backup-emergency-reader.json` (GCP service account key)
   - Fields: `bucket` = `nt-git-backups`, `project` = `neuraltrust-git-backup`
2. `gcloud` CLI on a trusted Mac (FileVault on).
3. Network access to `storage.googleapis.com`.

## 1. Authenticate with offline key

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/from-vault/backup-emergency-reader.json
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
gcloud config set project neuraltrust-git-backup
```

## 2. List available backup dates (last ~3 weeks)

```bash
gcloud storage ls gs://nt-git-backups/git-backups/ | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}/'
```

Pick the **oldest clean week** if you suspect recent compromise (attackers may have pushed malicious commits before backup).

## 3. Download consolidated manifest and verify

```bash
export BACKUP_DATE=2026-06-23   # example — use chosen date
mkdir -p "./restore/${BACKUP_DATE}"
gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/manifest.json" \
  "./restore/${BACKUP_DATE}/"
cat "./restore/${BACKUP_DATE}/manifest.json" | jq '.anomalies, .repo_count'
```

Review `anomalies` — prefer a date with **no commit-count drops** vs the prior week.

## 4. Restore a single repository

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

## 5. Bulk restore (all repos)

```bash
gcloud storage cp -r \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/*.bundle" \
  "./restore/${BACKUP_DATE}/bundles/"
for bundle in "./restore/${BACKUP_DATE}/bundles"/*.bundle; do
  name="$(basename "$bundle" .bundle)"
  git clone "$bundle" "./restore/${BACKUP_DATE}/out/${name}"
done
```

## 6. Post-restore

1. Compare restored `commit_count` / `sha256` with `manifest.json`.
2. Push to a **new** GitHub org or private fork before re-trusting production.
3. Rotate all secrets that may have been in git history.
4. Revoke and re-issue emergency SA key if the workstation was exposed.

## What this does NOT restore

- GitHub Actions / Environment secrets
- Deploy keys (private halves)
- Git LFS objects (unless added in a future workflow revision)
- Issues, PRs, wiki (unless in git)

## Key rotation

Rotate the emergency SA key annually or after any use:

```bash
gcloud iam service-accounts keys list --iam-account=backup-emergency-reader@neuraltrust-git-backup.iam.gserviceaccount.com
gcloud iam service-accounts keys delete KEY_ID --iam-account=backup-emergency-reader@...
./create-emergency-restore-sa.sh /tmp/new-key.json
# Upload new key to the team vault, delete old key + local file
```
