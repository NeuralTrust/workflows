# Org git backup — scope and limitations

## What is backed up

| Asset | Included |
|-------|----------|
| Git history (all branches, tags) | Yes — `git bundle` per repo |
| Per-repo SHA-256 checksum | Yes |
| Per-repo `commit_count` | Yes — for anomaly detection |
| Consolidated `manifest.json` | Yes |
| Org metadata (public API) | Yes — `org-metadata.json` |
| Weekly dated snapshots | Yes — 3 weeks retained (21-day lifecycle) |
| Dead-man heartbeat | Yes — `_control/heartbeat.json` |

## What is NOT backed up

| Asset | Notes |
|-------|-------|
| GitHub Actions secrets | Use separate vault export / Secret Manager |
| Environment secrets | Same |
| Deploy keys (private) | Not accessible via API |
| Git LFS objects | `git clone --mirror` does not fetch LFS |
| Issues / PRs / Projects | Not in git bundles |
| Packages registry | Separate process |

## Security controls (hardened PR)

- Isolated GCP project (`BACKUP_WIF_*`, not `PROD_WIF_*`)
- Read-only GitHub App (not org `GH_TOKEN` with write)
- GCS Object Lock (governed retention)
- 3-week retention for compromise recovery
- Commit-count anomaly vs prior week
- Daily dead-man's-switch watchdog
- Offline emergency restore SA (team credential vault)

## Object layout

```
gs://<bucket>/git-backups/
  _control/
    heartbeat.json
  2026-06-23/
    manifest.json
    org-metadata.json
    watchdog.bundle
    watchdog.bundle.sha256
    watchdog.manifest.json
  2026-06-30/
    ...
```
