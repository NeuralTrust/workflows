# Org backup — every repo, into Google Cloud Storage

Every Monday, each NeuralTrust repository is mirror-cloned, packed into a single
`.bundle` file and uploaded to a GCS bucket in its own GCP project.

A bundle is the **entire repository** — all branches, all tags, all history — in
one file. You restore it with `git clone`. Nothing else to install.

```
gs://neuraltrust-git-backup/git-backups/2026-09-21/
├── app.bundle
├── TrustGate.bundle
├── ...                      (~123 files, ~0.65 GB)
├── checksums.sha256         sha256sum -c
├── MANIFEST.txt             what ran, how it went
└── github-metadata/         PRs, issues and their discussion
    ├── app.json.gz
    └── ...                  (~123 files, ~6 MB)
```

| | |
| --- | --- |
| **Backed up** | All branches, tags and commit history of every org repo — archived ones included, plus pull requests, issues and their comments |
| **Kept for** | 180 days (~26 weekly snapshots) |
| **Costs** | ~$0.40/month |

Two workflows do it:

- [`repo-backup.yml`](../../.github/workflows/repo-backup.yml) — the weekly backup: code bundles and GitHub metadata, in two parallel jobs
- [`repo-backup-watchdog.yml`](../../.github/workflows/repo-backup-watchdog.yml) — daily check that the backup is still running

Either one, on failure, opens an issue in this repo that @-mentions the owners,
so the alert reaches a person by email rather than sitting in a run log.

## What is *not* backed up

This backs up code and history. Everything else GitHub holds is out of scope —
here is what that actually costs us:

| Left out | Would it break a restore? | Where we stand |
| --- | --- | --- |
| **Git LFS objects** | **Yes** | **No repo in the org uses LFS today.** See the warning below |
| Wikis | No | Empty — `has_wiki: true` is just GitHub's default, there is no content |
| Formal PR reviews (approvals) | No | Sampled as **0 across every PR checked** — the org merges without GitHub's review flow, so there is nothing to export. The discussion is all in comments, which *are* exported |
| Actions secret *values* | No | Not a choice — the GitHub API never returns a secret's value, not even to an org admin. They have to be rotated after an incident anyway |
| Releases, projects, org settings | No | Rebuildable, and not where the reasoning lives |

To get the **code** back, nothing is missing. Pull requests and issues used to be
on this list; they are now exported — see below.

## The metadata export

Git holds *what* changed. GitHub holds *why*. The `metadata` job exports the
second part into one gzipped JSON per repo:

```json
{
  "repository": "app",
  "exported_at": "2026-09-21T03:14:00Z",
  "pull_requests":   [ { "number": 3539, "title": "...", "body": "...",
                         "author": "...", "base": "develop", "head": "fix/...",
                         "merge_commit_sha": "...", "state": "closed" } ],
  "issues":          [ { "number": 12, "title": "...", "body": "..." } ],
  "comments":        [ { "issue": 3539, "author": "...", "body": "..." } ],
  "review_comments": [ { "pull": 3539, "path": "src/x.ts", "line": 42 } ]
}
```

Read one back without downloading anything:

```bash
gcloud storage cat gs://neuraltrust-git-backup/git-backups/2026-09-21/github-metadata/app.json.gz \
  | gunzip | jq '.pull_requests[] | select(.number == 3539)'
```

Two design notes:

- It runs as a **separate job, in parallel** with the bundles. A GitHub API
  hiccup must never stop the code backup from finishing.
- Raw GitHub JSON is mostly URL boilerplate — for `app` it is 79 MB. Keeping
  only the human-meaningful fields brings that to 9 MB, and 2 MB gzipped. The
  whole org costs ~6 MB per snapshot, against 650 MB of bundles.

> [!WARNING]
> **If any repo ever starts using Git LFS, this backup becomes incomplete for
> that repo** — the bundle stores LFS *pointer files*, not the actual content,
> and the restore looks fine until someone opens a file. Fixing it means adding
> `git lfs fetch --all` to the mirror step before bundling. Re-check with:
> ```bash
> gh search code --owner NeuralTrust "filter=lfs"
> ```

---

## Setup

Five phases, **in this order** — each one needs the one before it. About 45
minutes total, spread across three people.

### Phase 1 — GCP · *GCP admin* · ~10 min

You need `gcloud` and permission to create projects. No `gcloud` on your
machine? Use [Cloud Shell](https://shell.cloud.google.com) — it has everything.

**1.1** Run the script. It creates the project, bucket, service account and
GitHub authentication, and it is safe to re-run if something fails halfway.

```bash
gcloud billing accounts list          # copy the ACCOUNT_ID
export BILLING_ACCOUNT=0X0X0X-0X0X0X-0X0X0X
./docs/backup/setup-gcp.sh
```

**1.2** Keep the output — it prints the values you need in Phase 3.

**1.3** Check the bucket came out right:

```bash
gcloud storage buckets describe gs://neuraltrust-git-backup \
  --format="value(versioning.enabled,lifecycle.rule[0].condition.age)"
```

Expected: `True 180`

### Phase 2 — A read-only GitHub App · *org admin* · ~10 min

The backup must read all 123 repos. A GitHub App is used rather than a personal
token because it cannot write anything and it does not expire.

**2.1** https://github.com/organizations/NeuralTrust/settings/apps → **New GitHub App**

**2.2** Name it `NeuralTrust Backup`. **Uncheck Webhook → Active** — otherwise
GitHub demands a URL.

**2.3** Under **Repository permissions**, set exactly these four. Everything
else stays *No access*:

- Contents: **Read-only** — the code
- Metadata: **Read-only** — the repo list
- Issues: **Read-only** — issues and PR comments
- Pull requests: **Read-only** — PRs and review comments

**2.4** Create it, and note the **App ID**.

**2.5** **Generate a private key** → a `.pem` downloads. **You get it once.**

**2.6** Left menu → **Install App** → **All repositories**.

**2.7** Check the App can see everything:

```bash
gh api /orgs/NeuralTrust/repos --paginate --jq 'length'
```

Expected: ~123, not a 403.

### Phase 3 — Wire GitHub to GCP · *admin of this repo* · ~3 min

**3.1** [Secrets](https://github.com/NeuralTrust/workflows/settings/secrets/actions) — four of them:

| Secret | Where it comes from |
| --- | --- |
| `BACKUP_WIF_PROVIDER` | Phase 1 output |
| `BACKUP_WIF_SERVICE_ACCOUNT` | Phase 1 output |
| `BACKUP_APP_ID` | step 2.4 |
| `BACKUP_APP_PRIVATE_KEY` | the **whole** `.pem`, `-----BEGIN` line included |

**3.2** [Variables](https://github.com/NeuralTrust/workflows/settings/variables/actions) — one:

| Variable | Value |
| --- | --- |
| `BACKUP_GCS_BUCKET` | `neuraltrust-git-backup` |

### Phase 4 — Prove it works · *anyone with Actions access* · ~20 min

**Do not skip this phase.** Everything up to here is configuration; this is the
part that tells you the configuration is correct.

**4.1** Actions → **Org backup** → **Run workflow**. ~15 minutes.

**4.2** The run summary must show `Failed: 0`. If any repo fails the run goes
red on purpose — an incomplete snapshot is not a backup.

**4.3** Check what actually landed in GCS:

```bash
D=$(date -u +%Y-%m-%d)
gcloud storage cat "gs://neuraltrust-git-backup/git-backups/$D/MANIFEST.txt"
gcloud storage ls   "gs://neuraltrust-git-backup/git-backups/$D/" | wc -l
```

Expected: `backed_up` around 122, `failed: 0`, and ~125 entries.

Check the metadata landed too, and that it is readable:

```bash
gcloud storage cat "gs://neuraltrust-git-backup/git-backups/$D/github-metadata/app.json.gz" \
  | gunzip | jq '{prs: (.pull_requests|length), comments: (.comments|length)}'
```

Expected: a few thousand PRs and over a thousand comments.

**4.4** **Restore a real repository.** This is the step that turns this from an
assumption into a backup:

```bash
D=$(date -u +%Y-%m-%d)
gcloud storage cp "gs://neuraltrust-git-backup/git-backups/$D/app.bundle" /tmp/
git clone /tmp/app.bundle /tmp/restore-drill
git -C /tmp/restore-drill log -1
git -C /tmp/restore-drill branch -a | head
```

You should see the real latest commit of `app` and its branches.

**4.5** Actions → **Org backup watchdog** → **Run workflow**. It must pass — the
snapshot from 4.1 is zero days old.

### Phase 5 — Resilience and cleanup · ~5 min

**5.1** Confirm the three owners can read the bucket. `setup-gcp.sh` grants this
in Phase 1 — this is just checking it took:

```bash
gcloud projects get-iam-policy neuraltrust-backup \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/storage.objectViewer" \
  --format="value(bindings.members)"
```

Expected: `victor.garcia@`, `kadu.barral@` and `telm.olivella@`, plus the
service account. To change the list, re-run the script with `READERS` set.

**5.2** Delete the orphaned `GCS_BUCKET` variable, which no workflow uses:

```bash
gh variable delete GCS_BUCKET --repo NeuralTrust/workflows
```

**5.3** Put a **quarterly drill** in the calendar: repeat step 4.4. Two minutes,
and it is the only thing that catches a restore path that broke silently.

---

## Recovering the code after an incident

### One repository

```bash
gcloud storage cp gs://neuraltrust-git-backup/git-backups/2026-09-21/app.bundle .
git clone app.bundle app
```

That's it. `app/` is a normal git repo with full history. To push it to a new
GitHub repo:

```bash
cd app
git remote set-url origin https://github.com/NeuralTrust/app.git
git push --mirror origin
```

### Everything

```bash
DATE=2026-09-21
gcloud storage cp -r "gs://neuraltrust-git-backup/git-backups/${DATE}" .
cd "${DATE}"

sha256sum -c checksums.sha256          # confirms the download matches what we uploaded

for b in *.bundle; do
  git clone "$b" "${b%.bundle}"
done

# and the pull requests / issues that went with them
for m in github-metadata/*.json.gz; do gunzip -k "$m"; done
```

### If the GitHub org is gone entirely

The bundles are independent of GitHub — they are plain git. Restore them
locally with the commands above, then push them wherever you like. The pull
requests and issues are in `github-metadata/`, readable with `jq` — they cannot
be pushed back into a new org, but the reasoning is not lost.

What you do **not** get back: the values of Actions secrets, which must be
rotated after an incident anyway.

---

## Checking it still works

- **Automatic** — the watchdog runs daily and fails unless the newest snapshot
  is under 8 days old, reports zero failures, and holds at least 100
  repositories. Checking only the date would not be enough: the backup writes
  its manifest even when it fails, so a run that saved 3 repos out of 123 still
  leaves a folder dated today.

  **Who gets told.** Left to GitHub, a scheduled workflow notifies only whoever
  last edited the cron line — one person, chosen by accident of git history. So
  both workflows end in a `notify` job that, on failure, opens an issue
  @-mentioning the owners:

  | | |
  | --- | --- |
  | `@vgmartinez` | victor.garcia@neuraltrust.ai |
  | `@kadubarral-nt` | kadu.barral@neuraltrust.ai |
  | `@telmolivella2` | telm.olivella@neuraltrust.ai |

  A mention emails each of them through their normal GitHub notification
  settings — no SMTP credentials, no third-party action, no secret to rotate.
  The job reuses one open issue instead of filing a new one every run, so a
  backup that stays broken does not bury anyone's inbox.

  To change who is alerted, edit `OWNERS` in the `notify` job of both workflows.
  GitHub's API cannot subscribe somebody else to a repository, which is why this
  does not rely on people remembering to click *Watch*.
- **Manual, once a quarter** — repeat the restore drill from step 4.4 above. Two
  minutes. A backup nobody has ever restored is a guess, not a backup.

---

## Design notes

**Why one job and not a matrix of 123.** The whole org is 0.65 GB. One runner
does it sequentially in ~15 minutes. A job-per-repo matrix is 123x the
complexity for no gain.

**Why no Object Lock** (ENG-868 calls for a retention lock). The service account
holds `roles/storage.objectCreator` — it can add objects but has **no delete
permission at all**. With bucket versioning on, a stolen CI credential cannot
destroy old backups; the worst it can do is write a new version on top of one.
That covers the realistic threat.

A *locked* retention policy would additionally stop a compromised **GCP project
admin** from deleting the bucket's contents. That is a real threat, but a
narrower one, and locking is irreversible: the period can be raised forever and
never lowered, and the bucket cannot be emptied until everything ages out.
Applying an irreversible control to infrastructure that has not run once is a
bad trade. Ship without it; if an audit asks for the lock, it is one command
after the first restore drill has passed:

```bash
gcloud storage buckets update gs://neuraltrust-git-backup --retention-period=30d
gcloud storage buckets update gs://neuraltrust-git-backup --lock-retention-period
```

**Why GitHub Actions and not Cloud Run** (ENG-866 proposed a Cloud Run job).
Actions reuses the Workload Identity Federation pattern that 58 workflows in
this repo already use: no container to build and patch, no scheduler to
provision, no second deployment path.

The obvious objection is the shared failure domain — if the GitHub org is
suspended, the backup stops *and* so does the watchdog that would tell you.
That matters less than it looks. The watchdog exists to catch **silent**
failures: a broken credential, a wrong bucket, a schedule GitHub disabled after
60 days of inactivity. All of those still get caught. An org-wide GitHub outage
is not silent — nobody can push or open a pull request either — and the
snapshots already in GCS are untouched by it, which is the whole point. Revisit
this if Actions is ever deliberately turned off org-wide.

**Why 180 days and not 3 weeks.** Storage is $0.02/GB/month. Three weeks of
retention costs about $0.04/month and 180 days about $0.40. If someone rewrites
history and nobody notices for a month, three weeks of retention means it is
gone. The extra $0.36 removes that failure mode.

Note that a snapshot lives a bit longer than 180 days: with versioning on, the
lifecycle rule makes it *noncurrent* rather than erasing it, and a second rule
removes it 30 days after that. Budget for ~30 snapshots on disk, not 26.

**Why a separate GCP project.** If production GCP is compromised, the backups
must not be in the same blast radius. This is the single most valuable control
here, and it is five minutes of setup.
