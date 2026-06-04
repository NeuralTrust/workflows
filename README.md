# NeuralTrust Shared Workflows

Reusable GitHub Actions workflows for the NeuralTrust organization.

## Pipeline Architecture

Every repo follows the same standardized pipeline:

```
┌──────────────┐     ┌────────────────────────────────────────────────────────────────┐
│ Push develop │────▶│ deploy.yml → build + image scan + kustomize + Slack notify     │──▶ Dev
└──────────────┘     └────────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────────────────────────┐
│ PR → main    │────▶│ ci.yml → Tests + SAST/security + metadata validation         │
└──────────────┘     └──────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────────────┐
│ Push main    │────▶│ auto-release.yml → AI Semver Bump → GitHub Release│
└──────────────┘     └────────────────────────┬─────────────────────────┘
                                              │ triggers
                    ┌─────────────────────────▼──────────────────────────────────────┐
                    │ release.yml → Smart Release (promote or rebuild)               │
                    │                                                                │
                    │   develop→main PR?  ──YES──▶  SCAN → PROMOTE (crane copy)      │──▶ Prod
                    │   hotfix/direct?    ──YES──▶  REBUILD → SCAN                   │──▶ Prod
                    │                                                                │
                    │   Scan blocks CRITICAL/HIGH fixable CVEs (see image-scan.yml)  │
                    └────────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────────────┐
│ Weekly       │────▶│ Dependabot → dependency update PRs (auto)        │
└──────────────┘     └──────────────────────────────────────────────────┘
```

### Workflows Per Repo

| File | Trigger | What it does |
|------|---------|-------------|
| `deploy.yml` | Push to `develop` | Build with COMMIT_SHA → deploy to dev |
| `ci.yml` | PR to `main` | Tests + SAST/security + PR metadata validation |
| `auto-release.yml` | Push to `main` | AI determines semver bump → creates GitHub Release |
| `release.yml` | GitHub Release published | Smart release (promote or rebuild) → deploy to prod |

### Branching & Merge Strategy

| PR Target | Merge Method | Why |
|-----------|-------------|-----|
| Feature → `develop` | **Squash merge** | Keeps develop history clean, one commit per feature |
| `develop` → `main` | **Merge commit** | Preserves commit graph so histories stay in sync |

> **Important:** Using squash merge for `develop` → `main` causes history divergence — the next
> comparison will show old commits even though their content was already merged. Always use
> "Create a merge commit" when merging `develop` into `main`.

---

## Available Reusable Workflows

### Build & Deploy

| Workflow | Description |
|----------|-------------|
| [`docker-build-deploy.yml`](#docker-build--deploy) | Build + push + kustomize (single image, COMMIT_SHA) |
| [`multi-image-deploy.yml`](#multi-image-build--deploy) | Matrix build + kustomize (multiple images, COMMIT_SHA) |

### Release

| Workflow | Description |
|----------|-------------|
| [`release-promote.yml`](#smart-release-promote--rebuild) | **Recommended** — Smart release: promote from dev or rebuild (single image) |
| [`multi-image-release-promote.yml`](#multi-image-smart-release) | **Recommended** — Smart release for multi-image services |
| [`python-publish.yml`](#python-package-publish) | Build and publish Python package to GCP Artifact Registry (uv/poetry) |
| [`release-deploy.yml`](#release-deploy-legacy) | Legacy — Always rebuilds (single image, release tag) |
| [`multi-image-release.yml`](#multi-image-release-legacy) | Legacy — Always rebuilds (multiple images, release tag) |

### CI / Quality

| Workflow | Description |
|----------|-------------|
| [`tests.yml`](#tests--linting) | Generic test runner (Go/Python/Node/Rust) + optional services |
| [`sast.yml`](#sast--security) | Trivy + Gitleaks + language SAST (Gosec/Bandit/njsscan) |
| [`image-scan.yml`](#docker-image-scanning) | Trivy container image scan (warn on dev, block on prod release) |
| [`dast.yml`](#dast) | OWASP ZAP scan of running app (APIs/frontend); JWT or login-based auth |
| [`seo-check.yml`](#seo-static-audit) | Static Next.js SEO audit (metadata, sitemap/robots presence); job summary |
| [`seo-live-url.yml`](#seo-live-url) | Live site: homepage / `robots.txt` / sitemap content audit + Lighthouse SEO |
| [`ai-release-bump.yml`](#ai-release-bump) | AI-powered semver classification + GitHub Release creation (also promotes `## [Unreleased]` in CHANGELOG) |
| [`openspec-changelog.yml`](#openspec-changelog-feed) | Append openspec proposal summaries to `## [Unreleased]` in CHANGELOG on PR merge |

### Post-Deploy

| Workflow | Description |
|----------|-------------|
| [`smoke-test.yml`](#smoke-test) | Post-deploy health check with version polling |
| [`e2e-playwright.yml`](#e2e-playwright) | Playwright E2E tests from the `e2e-tests` image + Allure reporting |

### Building Blocks

| Workflow | Description |
|----------|-------------|
| [`build-push-image.yml`](#build--push-image) | Standalone Docker build + push (for advanced composition) |
| [`update-kustomization.yml`](#update-kustomization) | Update kustomization.yaml + commit/push |

---

## Which Release Workflow Should I Use?

```
Is your dev and prod registry in the same GCP project?
│
├─ NO (different projects) ← most NeuralTrust services
│  │
│  │  How many Docker images?
│  │
│  ├─ 1 image  → release-promote.yml (smart: promote + rebuild fallback)
│  │
│  └─ 2+ images → multi-image-release-promote.yml
│
└─ YES (same project)
   │
   ├─ 1 image  → release-deploy.yml (always rebuilds)
   │
   └─ 2+ images → multi-image-release.yml
```

---

## Smart Release (Promote + Rebuild)

**`release-promote.yml`** — The recommended release workflow. Automatically detects the best strategy:

| Scenario | Strategy | Time | What happens |
|----------|----------|------|-------------|
| develop → main PR merged | **Promote** | ~10 seconds | Scans dev image → copies to prod if clean (byte-identical) |
| Hotfix / direct push to main | **Rebuild** | ~2-5 minutes | Full Docker build → scan prod image before kustomize update |

### Image scan gate (prod only)

Before any prod tag is applied or kustomization is updated, the release image is scanned for **fixable CRITICAL/HIGH** CVEs. A failure blocks the release and sends a Slack alert.

| Strategy | Image scanned | When copy/build completes |
|----------|---------------|---------------------------|
| **Promote** | Dev source image (by commit SHA) | Crane copy runs **after** scan passes — a dirty dev image never gets a prod release tag |
| **Rebuild** | Freshly built prod image | Kustomize update runs **after** scan passes |

Dev deploys use the same scanner in **warn mode** (`exit_code: 0`) — findings appear in the job summary and GitHub Security tab but never block deployment.

### How detection works

1. Queries the GitHub API for PRs associated with the release commit
2. If a merged PR from `develop` → `main` is found:
   - Gets the develop branch tip SHA from the PR
   - Verifies the dev image exists in the dev registry (by commit SHA)
   - If found → **promote** (crane copy)
   - If not found → falls back to **rebuild**
3. If no develop→main PR → **rebuild** (hotfix path)

### Release job flow

```
release (detect strategy + build if hotfix)
    │
    ▼
scan (Trivy — blocks on fixable CRITICAL/HIGH)
    │
    ├─ promote ──▶ promote-copy (crane dev → prod)
    │
    └─ rebuild ──▶ (promote-copy skipped)
    │
    ▼
update-kustomization + Slack notify
```

### Benefits of promote

- **Zero build time** — image copy takes ~10 seconds vs minutes for a full build
- **Byte-identical binary** — what was tested in dev is exactly what runs in prod
- **Scan-before-promote** — prod tags are only applied after the dev image passes the vulnerability gate
- **Version injection via ConfigMap** — `APPLICATION_VERSION` is set in `config.env`, picked up by kustomize `configMapGenerator`, and overrides the build-time value at runtime

### Quick Start

```yaml
# .github/workflows/release.yml
name: Release
on:
  release:
    types: [published]

permissions:
  contents: write
  id-token: write

jobs:
  release:
    uses: NeuralTrust/workflows/.github/workflows/release-promote.yml@main
    with:
      image_name: my-service
      gcp_project_id: ${{ vars.PROD_GCP_PROJECT_ID }}
      dev_gcp_project_id: ${{ vars.DEV_GCP_PROJECT_ID }}
    secrets:
      WIF_PROVIDER: ${{ secrets.PROD_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.PROD_WIF_SERVICE_ACCOUNT }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

With build args (used only for the rebuild/hotfix fallback):

```yaml
jobs:
  release:
    uses: NeuralTrust/workflows/.github/workflows/release-promote.yml@main
    with:
      image_name: my-service
      gcp_project_id: ${{ vars.PROD_GCP_PROJECT_ID }}
      dev_gcp_project_id: ${{ vars.DEV_GCP_PROJECT_ID }}
      build_args: |
        VERSION=${{ github.event.release.tag_name }}
        GIT_COMMIT=${{ github.sha }}
    secrets:
      WIF_PROVIDER: ${{ secrets.PROD_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.PROD_WIF_SERVICE_ACCOUNT }}
      BUILD_SECRETS: |
        GITHUB_TOKEN=${{ secrets.GH_TOKEN }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
      SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `image_name` | Yes | — | Docker image name in the registry |
| `gcp_project_id` | Yes | — | Prod GCP Project ID (destination) |
| `dev_gcp_project_id` | Yes | — | Dev GCP Project ID (source for promote) |
| `registry` | No | `europe-west1-docker.pkg.dev` | Artifact Registry host |
| `repository` | No | `nt-docker` | Artifact Registry repository |
| `dockerfile` | No | `Dockerfile` | Dockerfile path (rebuild only) |
| `context` | No | `.` | Build context (rebuild only) |
| `build_target` | No | — | Multi-stage target (rebuild only) |
| `build_args` | No | — | Build args (rebuild only) |
| `tag_prefix` | No | — | Tag prefix (e.g., `gpu-`) |
| `tag_suffix` | No | — | Tag suffix |
| `kustomize_name` | No | `image_name` | Image name in kustomization.yaml |
| `overlay_path` | No | `k8s/overlays/prod` | Prod kustomize overlay path |
| `config_env_file` | No | `config.env` | Config env file name in overlay |
| `dev_branch` | No | `develop` | Dev branch name (for PR detection) |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `WIF_PROVIDER` | Yes | GCP Workload Identity Federation provider |
| `WIF_SERVICE_ACCOUNT` | Yes | GCP service account email |
| `BUILD_SECRETS` | No | Secret build args (rebuild only) |
| `GH_TOKEN` | Yes | GitHub PAT for kustomization pushes |
| `SLACK_WEBHOOK_URL` | No | Slack webhook for notifications |

---

## Multi-Image Smart Release

**`multi-image-release-promote.yml`** — Same smart promote/rebuild logic for multi-image services.

```yaml
jobs:
  release:
    uses: NeuralTrust/workflows/.github/workflows/multi-image-release-promote.yml@main
    with:
      images: |
        [
          {"name": "my-service", "target": "api"},
          {"name": "my-service-cli", "target": "cli"}
        ]
      kustomize_images: |
        [
          {"kustomize_name": "my-service", "image_name": "my-service"},
          {"kustomize_name": "my-service-cli", "image_name": "my-service-cli"}
        ]
      gcp_project_id: ${{ vars.PROD_GCP_PROJECT_ID }}
      dev_gcp_project_id: ${{ vars.DEV_GCP_PROJECT_ID }}
      commit_message_prefix: my-service
    secrets:
      WIF_PROVIDER: ${{ secrets.PROD_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.PROD_WIF_SERVICE_ACCOUNT }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
      SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

Detection runs once; each image is released in parallel via a matrix job. Per image:

```
release (detect strategy + build if rebuild) → scan (image-scan.yml) → promote-copy → update-kustomization
```

Each image is scanned for fixable CRITICAL/HIGH CVEs **before** crane copy or kustomize update — same gate as single-image `release-promote.yml`.

---

## APPLICATION_VERSION & Health Endpoints

### Standard health endpoint format

All services expose a `/health` endpoint returning:

```json
{
  "status": "healthy",
  "version": "v1.2.3",
  "time": "2026-02-07T20:06:41Z"
}
```

### How version is injected

The version flows through two mechanisms:

| Environment | Mechanism | Value |
|-------------|-----------|-------|
| **Dev** (develop push) | Dockerfile `ENV APPLICATION_VERSION=${APP_VERSION}` | Commit SHA |
| **Prod** (release) | Kubernetes ConfigMap via `config.env` → `APPLICATION_VERSION=v1.2.3` | Release tag |

In production, the ConfigMap env var overrides the Dockerfile value because Kubernetes env vars take precedence.

### Language-specific implementation

**Go** — `init()` function reads from env, overriding ldflags:

```go
func init() {
    if v := os.Getenv("APPLICATION_VERSION"); v != "" {
        Version = v
    }
}
```

**Python** — reads from env directly:

```python
app_version = os.environ.get("APPLICATION_VERSION", "unknown")
```

**Node.js** — reads from env directly:

```typescript
version: process.env.APPLICATION_VERSION || 'unknown'
```

### config.env management

All deploy/release workflows automatically update `APPLICATION_VERSION` in the overlay's `config.env`:

- Dev deploy: `APPLICATION_VERSION=<commit-sha>`
- Prod release: `APPLICATION_VERSION=<release-tag>` (e.g., `v1.2.3`)

The kustomize `configMapGenerator` picks this up, regenerates the ConfigMap with a new hash suffix, and Kubernetes triggers a rollout.

---

## AI Release Bump

**`ai-release-bump.yml`** — Analyzes commits since the last release using OpenAI and determines the appropriate [semver](https://semver.org/) bump:

- **MAJOR** — incompatible API changes, breaking changes
- **MINOR** — new features, backward-compatible functionality
- **PATCH** — bug fixes, docs, refactoring, dependency updates

Then creates a **GitHub Release** with the new version tag. The release event triggers the repo's `release.yml` for deployment.

### Quick Start

```yaml
# .github/workflows/auto-release.yml
name: Auto Release
on:
  push:
    branches: [main]

permissions:
  contents: write

jobs:
  release:
    uses: NeuralTrust/workflows/.github/workflows/ai-release-bump.yml@main
    secrets:
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `model` | `gpt-4o-mini` | OpenAI model for classification |
| `default_bump` | `patch` | Fallback if AI classification fails |
| `initial_version` | `v0.1.0` | Version for repos with no previous tags |
| `tag_prefix` | `v` | Prefix for version tags |
| `dry_run` | `false` | Compute version without creating release |
| `version_update_script` | `''` | Shell commands to update version files. Receives `VERSION` and `TAG` env vars. |
| `update_changelog` | `true` | If true, promote `## [Unreleased]` → `## [vX.Y.Z] — YYYY-MM-DD` in the changelog file before tagging. |
| `changelog_path` | `CHANGELOG.md` | Path of the changelog file to promote. |
| `unreleased_heading` | `## [Unreleased]` | Heading used for the unreleased section in the changelog. |

### Outputs

| Output | Description |
|--------|-------------|
| `new_version` | The new version tag (e.g., `v1.2.3`) |
| `bump_type` | The bump type (`major`, `minor`, `patch`) |
| `previous_version` | The previous version tag |

### Release notes

The workflow creates a minimal GitHub Release body:

- **What changed** — bump type and AI reason
- **Commits** — list since the previous tag

It does **not** append installation instructions, container image tables, or an AI semver footer. Repos that need those (e.g. `neuraltrust-platform`) extend the release in a follow-up workflow (`publish-chart.yml` appends **Container images** and **Installation**).

### Loop Guard

The bump-guard skips this workflow when the head commit message starts with:

- `chore: bump version to …` — this workflow's own version bump commit.
- `docs(changelog):` — entries written by [`openspec-changelog.yml`](#openspec-changelog-feed).

If you configure additional automated commits that push to `main`, prefix them similarly so they don't retrigger the release pipeline.

> **Important:** `GH_TOKEN` must be a PAT (not `GITHUB_TOKEN`) so the created release event can trigger other workflows.

---

## OpenSpec Changelog Feed

**`openspec-changelog.yml`** — On every PR merged into `main`, scans the PR for `proposal.md` files under the configured openspec directories and appends a one-line entry per change to `## [Unreleased]` in `CHANGELOG.md`. The entry is categorized following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

### Proposal frontmatter contract

Each `openspec/changes/<name>/proposal.md` (and `openspec/fixes/<name>/proposal.md`) drives one changelog entry:

```yaml
---
linear: ENG-415          # optional, used to link the Linear issue
type: breaking           # required: breaking | feat | fix | refactor | perf | chore | docs | security
changelog: "Forwarding rules ahora apuntan directo a upstreams; /services removido y service_id → upstream_id."
---

# Proposal: Deprecate the Service entity
```

Mapping `type:` → section:

| `type` | Section |
|---|---|
| `breaking` | `### Breaking` |
| `feat` / `feature` | `### Added` |
| `fix` | `### Fixed` |
| `refactor` / `perf` / `chore` | `### Changed` |
| `docs` | `### Docs` |
| `security` | `### Security` |

### Quick Start

```yaml
# .github/workflows/changelog.yml
name: OpenSpec Changelog Feed
on:
  pull_request:
    types: [closed]
    branches: [main]

permissions:
  contents: write

jobs:
  feed:
    if: github.event.pull_request.merged == true
    uses: NeuralTrust/workflows/.github/workflows/openspec-changelog.yml@main
    secrets:
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `changelog_path` | `CHANGELOG.md` | Path of the CHANGELOG file to update |
| `unreleased_heading` | `## [Unreleased]` | Heading for the unreleased section (must match exactly) |
| `scope_dirs` | `openspec/changes,openspec/fixes` | Comma-separated list of openspec directories to scan |
| `linear_team` | `neuraltrust` | Linear team slug used when proposal carries `linear: ENG-XXX` |
| `commit_message_prefix` | `docs(changelog):` | Prefix used for the changelog commit. Must be allow-listed by `ai-release-bump.yml` bump-guard. |

### How it composes with auto-release

```
PR merged to main
        │
        ├─▶ openspec-changelog.yml ── appends to ## [Unreleased] and pushes
        │       commit: docs(changelog): add entry for #NN
        │       (auto-release skips this push via bump-guard)
        │
        └─▶ auto-release.yml (push to main from the merge commit)
              ├─ AI determines semver bump
              ├─ Promotes ## [Unreleased] → ## [vX.Y.Z] — YYYY-MM-DD
              └─ Creates GitHub Release at the bump commit
```

The Unreleased section accumulates entries from each merged PR, and `auto-release.yml` snapshots them under a versioned heading at release time.

> **Important:** `GH_TOKEN` must be a PAT with `contents:write` on the caller repo, since the workflow pushes to `main`.

---

## Tests & Linting

**`tests.yml`** — Generic test runner supporting multiple languages with optional service containers.

### Supported Languages

| Language | Setup | Default Lint | Default Test |
|----------|-------|-------------|-------------|
| `go` | `actions/setup-go` | `golangci-lint run --timeout=10m ./...` | `go test -v -race -coverprofile=coverage.txt ./...` |
| `python` | `actions/setup-python` | `ruff check .` | `pytest -v --cov --cov-report=xml` |
| `node` | `actions/setup-node` | `npx eslint .` | `npm test` |
| `rust` | `dtolnay/rust-toolchain` | `cargo fmt --check && cargo clippy -D warnings` | `cargo test --verbose` |

### Optional Services

Start service containers with health checks and auto-exported env vars:

| Service | Input | Env Vars Exported |
|---------|-------|-------------------|
| PostgreSQL | `postgres_enabled: true` | `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_URL` |
| ClickHouse | `clickhouse_enabled: true` | `CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`, `CLICKHOUSE_HTTP_PORT`, `CLICKHOUSE_URL` |
| Redis | `redis_enabled: true` | `REDIS_HOST`, `REDIS_PORT`, `REDIS_URL` |
| Kafka (KRaft) | `kafka_enabled: true` | `KAFKA_SERVER`, `KAFKA_BOOTSTRAP_SERVERS` |

### Quick Start

```yaml
# Minimal (Go)
jobs:
  test:
    uses: NeuralTrust/workflows/.github/workflows/tests.yml@main
    with:
      language: go
      language_version: '1.25.1'
```

```yaml
# Split tests (recommended pattern — lint only once, services only where needed)
jobs:
  unit-tests:
    uses: NeuralTrust/workflows/.github/workflows/tests.yml@main
    with:
      language: go
      language_version: '1.25.1'
      go_private_modules: true
      lint_enabled: true
      coverage_enabled: true
      test_command: |
        go test -v -race -coverprofile=coverage.txt -covermode=atomic ./internal/...
      setup_commands: |
        cp .env.example .env
    secrets:
      GH_TOKEN: ${{ secrets.GH_TOKEN }}

  integration-tests:
    uses: NeuralTrust/workflows/.github/workflows/tests.yml@main
    with:
      language: go
      language_version: '1.25.1'
      go_private_modules: true
      lint_enabled: false
      postgres_enabled: true
      postgres_db: my_app
      redis_enabled: true
      test_command: |
        go test -v -race ./tests/integration
    secrets:
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
      TEST_SECRETS: |
        OPENAI_API_KEY=${{ secrets.OPENAI_API_KEY }}
```

```yaml
# Python with Kafka + PostgreSQL
jobs:
  test:
    uses: NeuralTrust/workflows/.github/workflows/tests.yml@main
    with:
      language: python
      language_version: '3.12'
      postgres_enabled: true
      kafka_enabled: true
      coverage_enabled: true
      coverage_file: coverage.xml
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `language` | Yes | — | `go`, `python`, `node`, `rust` |
| `language_version` | Yes | — | Version string (e.g., `1.25.1`, `3.12`, `20`, `1.78`) |
| `test_enabled` | No | `true` | Enable test execution |
| `test_command` | No | *(auto)* | Custom test command (overrides language default) |
| `lint_enabled` | No | `true` | Enable linting |
| `lint_command` | No | *(auto)* | Custom lint command (overrides language default) |
| `ty_enabled` | No | `false` | Run Astral `ty check` during default Python linting (preview type checker) |
| `coverage_enabled` | No | `false` | Generate coverage report in job summary |
| `coverage_file` | No | `coverage.txt` | Coverage file path |
| `working_directory` | No | `.` | Working directory for all commands |
| `setup_commands` | No | — | Commands to run before tests (e.g., install deps, copy env files) |
| `uv_sync_args` | No | `--frozen --all-extras --all-groups` | Arguments for `uv sync` (Python only). Override when extras conflict, e.g. `--frozen --extra cpu --extra dev` |
| `go_private_modules` | No | `false` | Enable private Go module access for `github.com/NeuralTrust/*` |
| `kreuzberg_enabled` | No | `false` | Install Kreuzberg FFI + Tesseract OCR before tests (Go CGO builds) |
| `kreuzberg_version` | No | `v4.1.0` | Kreuzberg FFI release version (only when `kreuzberg_enabled: true`) |

**Service inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `postgres_enabled` | `false` | Start PostgreSQL container |
| `postgres_version` | `16` | PostgreSQL version |
| `postgres_db` | `testdb` | Database name |
| `postgres_user` | `postgres` | Database user |
| `postgres_password` | `postgres` | Database password |
| `clickhouse_enabled` | `false` | Start ClickHouse container |
| `clickhouse_version` | `24` | ClickHouse version |
| `redis_enabled` | `false` | Start Redis container |
| `redis_version` | `7` | Redis version |
| `kafka_enabled` | `false` | Start Kafka (KRaft mode) container |
| `kafka_version` | `7.6.0` | Confluent Kafka version |

**Secrets:**

| Secret | Required | Description |
|--------|----------|-------------|
| `GH_TOKEN` | No | GitHub token for private module/repo access |
| `TEST_SECRETS` | No | Additional secrets as `KEY=VALUE` pairs (one per line), exported as env vars |

### Jobs

The workflow runs two parallel jobs:

1. **Lint** — Language-specific linting (skipped if `lint_enabled: false`)
2. **Test** — Service startup + setup_commands + test execution (skipped if `test_enabled: false`)

---

## SAST & Security

**`sast.yml`** — Multi-layered security scanning with universal tools and language-specific SAST:

**Universal (all repos):**

| Tool | Category | What it finds |
|------|----------|---------------|
| **Trivy** | SCA (dependencies) | Known CVEs in dependencies, IaC misconfigs, license issues |
| **Gitleaks** | Secret detection | Hardcoded secrets/credentials in git history |

**Language SAST (source code analysis, opt-in per language):**

| Tool | Language | What it finds |
|------|----------|---------------|
| **Gosec** | Go | SQL injection, weak crypto, command injection, hardcoded creds |
| **Bandit** | Python | SQL injection, insecure functions (`eval`, `exec`, `pickle`), hardcoded passwords, weak crypto |
| **njsscan** | Node/JS | XSS, prototype pollution, insecure regex, eval injection, command injection |
| *(not needed)* | Rust | Rust's type system + borrow checker + clippy covers most issues |

### Quick Start

```yaml
# Go projects
jobs:
  security:
    uses: NeuralTrust/workflows/.github/workflows/sast.yml@main
    with:
      gosec_enabled: true
```

```yaml
# Python projects
jobs:
  security:
    uses: NeuralTrust/workflows/.github/workflows/sast.yml@main
    with:
      bandit_enabled: true
      bandit_args: '-r src/ -ll -x tests'
```

```yaml
# Node projects
jobs:
  security:
    uses: NeuralTrust/workflows/.github/workflows/sast.yml@main
    with:
      njsscan_enabled: true
```

### Required caller permissions

`sast.yml` uploads Trivy results to the **Security tab** via `codeql-action/upload-sarif`. On **private** repos that needs both `security-events: write` **and** `actions: read` (the action reads the workflow-run status through the Actions API; without `actions: read` it fails with `Resource not accessible by integration`). A reusable workflow can't exceed the caller's token, so grant both in the caller:

```yaml
permissions:
  contents: read
  security-events: write
  actions: read          # ← required for SARIF upload on private repos
jobs:
  security:
    uses: NeuralTrust/workflows/.github/workflows/sast.yml@main
```

The SARIF upload itself is `continue-on-error`, so a missing `actions: read` won't fail CI — it just means findings won't reach the Security tab. The blocking gate is the Trivy table scan (`trivy_exit_code`), which is independent of SARIF upload.

> **Heads up:** even with both permissions, the Security-tab upload only works if **GitHub Advanced Security / code scanning is enabled on the repo**. Where it isn't, the upload logs `Code Security must be enabled for this repository` and is skipped (it never fails CI, thanks to `continue-on-error`). Findings are still visible in the **job log** (table scan). Enabling code scanning is an org/admin setting, not something the workflow can grant.

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `trivy_severity` | `CRITICAL,HIGH` | Severity levels to scan |
| `trivy_exit_code` | `1` | Exit code on findings (`1`=fail, `0`=warn) |
| `scan_type` | `fs` | Trivy scan type (`fs`, `config`, `repo`) |
| `gitleaks_enabled` | `false` | Enable informational secret detection across full git history |
| `gosec_enabled` | `false` | Enable Go SAST |
| `gosec_args` | `./...` | Gosec arguments |
| `bandit_enabled` | `false` | Enable Python SAST |
| `bandit_args` | `-r . -ll` | Bandit arguments |
| `njsscan_enabled` | `false` | Enable Node/JS SAST |
| `njsscan_args` | `.` | njsscan target path |

---

## DAST (Dynamic Application Security Testing)

**`dast.yml`** — Scans a **running** application (API or frontend) with OWASP ZAP. Use it after deploy so the target URL is live.

- **APIs with JWT**: Pass the token via secret (`auth_method: jwt_static`) or obtain it from your login endpoint (`auth_method: jwt_login`). ZAP sends `Authorization: Bearer <token>` on every request so protected endpoints are scanned.
- **Frontend (many screens)**: Point ZAP at the app URL; it spiders and scans. For login-protected UIs, use JWT if your app uses it, or see [docs/DAST.md](docs/DAST.md) for form-based auth options.

Full guide (auth options, inputs, secrets): **[docs/DAST.md](docs/DAST.md)**.

```yaml
# Example: API with JWT from login (run after deploy)
jobs:
  dast:
    needs: deploy
    uses: NeuralTrust/workflows/.github/workflows/dast.yml@main
    with:
      target_url: https://api.dev.example.com
      auth_method: jwt_login
      auth_login_url: https://api.dev.example.com/auth/login
      jwt_response_path: .access_token
    secrets:
      AUTH_USERNAME: ${{ secrets.DAST_TEST_USER }}
      AUTH_PASSWORD: ${{ secrets.DAST_TEST_PASSWORD }}
```

---

## SEO static audit

**`seo-check.yml`** — Fast static scan via `scripts/seo-static-audit.mjs` (metadata, `robots` / sitemap routes, common gaps). See workflow file header for `workflow_call` inputs.

## SEO live URL

**Example static site repo** (e.g. `web-public` `.github/workflows/site.yml`): on PR — **static** `seo-check.yml` plus **bundle** `npm run build:budget` in parallel; on push to `main` — **`seo-live-url.yml`** when repo variable **`BASE_URL`** is set. Copy `site.yml` into other repos and adjust `app_roots` / scripts as needed.

**`seo-live-url.yml`** — `curl` homepage, optional `robots.txt` + sitemap HEAD, then **`seo-live-content-audit.mjs`**: parse sitemap(s), validate `<loc>` URLs (scheme/host vs `base_url`), sample **HEAD/GET** on up to N URLs, check **`robots.txt`** for `Sitemap:` lines, and on homepage + Lighthouse paths audit **H1**, **`<link rel="canonical">`**, and **`application/ld+json`** (valid JSON). Then Lighthouse SEO on **`base_url`**. Inputs: `content_audit_enabled`, `content_audit_max_url_checks`, `content_audit_strict`. Set repository variable **`BASE_URL`**; job skipped when unset.

---

## Docker Build & Deploy

**`docker-build-deploy.yml`** — Builds a single Docker image with **COMMIT_SHA** tags, updates kustomization and config.env, and sends Slack notifications.

```yaml
# .github/workflows/deploy.yml
name: Build & Deploy
on:
  push:
    branches: [develop]

permissions:
  contents: write
  id-token: write

jobs:
  deploy:
    uses: NeuralTrust/workflows/.github/workflows/docker-build-deploy.yml@main
    with:
      image_name: my-service
      gcp_project_id: ${{ vars.DEV_GCP_PROJECT_ID }}
    secrets:
      WIF_PROVIDER: ${{ secrets.DEV_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.DEV_WIF_SERVICE_ACCOUNT }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `image_name` | Yes | — | Docker image name in registry |
| `gcp_project_id` | Yes | — | GCP Project ID |
| `registry` | No | `europe-west1-docker.pkg.dev` | Registry host |
| `repository` | No | `nt-docker` | Artifact Registry repo |
| `dockerfile` | No | `Dockerfile` | Dockerfile path (relative to context) |
| `context` | No | `.` | Docker build context |
| `build_target` | No | — | Docker multi-stage target |
| `build_args` | No | — | Non-secret build args (KEY=VALUE, one per line) |
| `tag_prefix` | No | — | Tag prefix (e.g., `gpu-`) |
| `tag_suffix` | No | — | Tag suffix (e.g., `-with-models`) |
| `kustomize_name` | No | `image_name` | Image name in kustomization.yaml |
| `overlay_dev_path` | No | `k8s/overlays/dev` | Dev overlay path |
| `overlay_prod_path` | No | `k8s/overlays/prod` | Prod overlay path |
| `free_disk_space` | No | `false` | Free ~30GB disk before build (needed for large base images like pytorch/cuda) |

### What it does

1. Builds Docker image with tags: `COMMIT_SHA`, `latest`, `cache`
2. Injects `APP_VERSION=<commit-sha>` as a build arg
3. Scans the pushed image via [`image-scan.yml`](#docker-image-scanning) (CRITICAL/HIGH, warn mode — never blocks dev)
4. Updates `kustomization.yaml` (image tag) and `config.env` (`APPLICATION_VERSION`) in parallel with the scan
5. Commits and pushes overlay updates (deploy workflows use `paths-ignore: k8s/**` so this does not retrigger builds)
6. Sends Slack notification

---

## Release Deploy (Legacy)

**`release-deploy.yml`** — Always rebuilds the Docker image. Use `release-promote.yml` instead for cross-project registries.

```yaml
jobs:
  release:
    uses: NeuralTrust/workflows/.github/workflows/release-deploy.yml@main
    with:
      image_name: my-service
      gcp_project_id: ${{ vars.PROD_GCP_PROJECT_ID }}
    secrets:
      WIF_PROVIDER: ${{ secrets.PROD_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.PROD_WIF_SERVICE_ACCOUNT }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

---

## Multi-Image Build & Deploy

**`multi-image-deploy.yml`** — Matrix-based parallel build of multiple images + kustomization update.

```yaml
jobs:
  deploy:
    uses: NeuralTrust/workflows/.github/workflows/multi-image-deploy.yml@main
    with:
      images: '[{"name":"api","target":"api"},{"name":"worker","target":"worker"}]'
      kustomize_images: '[{"kustomize_name":"api","image_name":"api"}]'
      gcp_project_id: ${{ vars.DEV_GCP_PROJECT_ID }}
    secrets:
      WIF_PROVIDER: ${{ secrets.DEV_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.DEV_WIF_SERVICE_ACCOUNT }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

### Image Build Config

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | — | Docker image name |
| `target` | No | — | Build target |
| `context` | No | `.` | Build context |
| `dockerfile` | No | `Dockerfile` | Dockerfile path |
| `build_args` | No | — | Extra build args |
| `tag_prefix` | No | — | Tag prefix |
| `tag_suffix` | No | — | Tag suffix |

---

## Multi-Image Release (Legacy)

**`multi-image-release.yml`** — Always rebuilds. Use `multi-image-release-promote.yml` instead.

---

## Python Package Publish

**`python-publish.yml`** — Builds a Python package (wheel + sdist) and publishes it to a GCP Artifact Registry Python repository. Supports both `uv` and `poetry` build tools.

### Quick Start

```yaml
# Using uv (default) — e.g., TrustTest
jobs:
  publish:
    uses: NeuralTrust/workflows/.github/workflows/python-publish.yml@main
    with:
      gcp_project_id: ${{ vars.PROD_GCP_PROJECT_ID }}
    secrets:
      WIF_PROVIDER: ${{ secrets.PROD_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.PROD_WIF_SERVICE_ACCOUNT }}
```

```yaml
# Using poetry — e.g., internal-sdk
jobs:
  publish:
    uses: NeuralTrust/workflows/.github/workflows/python-publish.yml@main
    with:
      gcp_project_id: ${{ vars.PROD_GCP_PROJECT_ID }}
      build_tool: poetry
      python_version: '3.10'
    secrets:
      WIF_PROVIDER: ${{ secrets.PROD_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.PROD_WIF_SERVICE_ACCOUNT }}
```

### Typical Pipeline

Python library repos follow a slightly different pattern from Docker-based services:

```
┌──────────────┐     ┌──────────────────────────────────────────────────────┐
│ Push develop │────▶│ publish-dev.yml → python-publish → DEV AR registry   │
└──────────────┘     └──────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────────────────┐
│ PR → main    │────▶│ ci.yml → Lint + SAST/security + metadata validation   │
└──────────────┘     └──────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────┐
│ Push main    │────▶│ auto-release.yml → AI Semver Bump + GitHub│
│              │     │ Release + update pyproject.toml version    │
└──────────────┘     └─────────────────┬────────────────────────┘
                                       │ triggers
                    ┌──────────────────▼──────────────────────────────────┐
                    │ release.yml → python-publish → PROD AR registry     │
                    └────────────────────────────────────────────────────┘
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `gcp_project_id` | Yes | — | GCP Project ID that owns the Artifact Registry |
| `build_tool` | No | `uv` | Build tool: `uv` or `poetry` |
| `python_version` | No | `3.11` | Python version |
| `ar_location` | No | `europe-west1` | Artifact Registry location |
| `ar_repository` | No | `nt-python` | Artifact Registry Python repository name |
| `working_directory` | No | `.` | Working directory containing `pyproject.toml` |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `WIF_PROVIDER` | Yes | GCP Workload Identity Federation provider |
| `WIF_SERVICE_ACCOUNT` | Yes | GCP service account email |

---

## Smoke Test

**`smoke-test.yml`** — Post-deploy health check that polls a service endpoint waiting for the expected version. Designed for FluxCD/GitOps where deployment is async.

### Outcomes

| Result | What happened | Slack | Exit code |
|--------|---------------|-------|-----------|
| **SUCCESS** | New version detected within timeout | None (or green) | 0 |
| **WARNING** | Service healthy but old version still running | Orange alert | 0 |
| **PROBLEM** | Service not responding at all | Red alert | 1 |

### Quick Start

```yaml
# Smoke test after dev deploy
jobs:
  deploy:
    uses: NeuralTrust/workflows/.github/workflows/docker-build-deploy.yml@main
    with:
      image_name: my-service
      gcp_project_id: ${{ vars.DEV_GCP_PROJECT_ID }}
    secrets:
      WIF_PROVIDER: ${{ secrets.DEV_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.DEV_WIF_SERVICE_ACCOUNT }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}

  smoke-test:
    needs: deploy
    uses: NeuralTrust/workflows/.github/workflows/smoke-test.yml@main
    with:
      health_url: https://api.dev.example.com/health
      expected_version: ${{ github.sha }}
      environment: dev
    secrets:
      SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `health_url` | Yes | — | URL to poll (must return 200 with version in body) |
| `expected_version` | Yes | — | Version string to grep for (commit SHA or release tag) |
| `timeout_minutes` | No | `10` | Max minutes to wait |
| `poll_interval` | No | `30` | Seconds between polls |
| `initial_delay` | No | `30` | Seconds to wait before first poll |
| `environment` | No | `dev` | Environment name for notifications |
| `service_name` | No | repo name | Service name for notifications |

### How It Works

1. Waits `initial_delay` seconds (gives FluxCD time to detect the kustomization change)
2. Polls `health_url` every `poll_interval` seconds
3. If response contains `expected_version` → **SUCCESS**
4. After `timeout_minutes`, checks one final time:
   - Service responds but version doesn't match → **WARNING**
   - Service doesn't respond → **PROBLEM**
5. Sends Slack notification for WARNING and PROBLEM outcomes

---

## E2E Playwright

**`e2e-playwright.yml`** — Runs Playwright tests from the shared `e2e-tests` Docker image against a deployed service, publishes results to Allure, and uploads HTML/Allure artifacts.

### Quick Start

```yaml
# After dev deploy
jobs:
  deploy:
    uses: NeuralTrust/workflows/.github/workflows/docker-build-deploy.yml@main
    # ...

  e2e:
    needs: deploy
    uses: NeuralTrust/workflows/.github/workflows/e2e-playwright.yml@main
    with:
      service: app
      base_url: https://app.dev.neuraltrust.ai
      expected_version: ${{ github.sha }}
      e2e_tests_channel: prod
      image_tag: latest
    secrets:
      TWINGATE_SERVICE_KEY: ${{ secrets.TWINGATE_SERVICE_KEY }}
      ALLURE_USER: ${{ secrets.ALLURE_USER }}
      ALLURE_PASS: ${{ secrets.ALLURE_PASS }}
      PROD_WIF_PROVIDER: ${{ secrets.PROD_WIF_PROVIDER }}
      PROD_WIF_SERVICE_ACCOUNT: ${{ secrets.PROD_WIF_SERVICE_ACCOUNT }}
      DEV_WIF_PROVIDER: ${{ secrets.DEV_WIF_PROVIDER }}
      DEV_WIF_SERVICE_ACCOUNT: ${{ secrets.DEV_WIF_SERVICE_ACCOUNT }}
      E2E_SECRETS_JSON: ${{ secrets.E2E_APP_SECRETS_JSON }}
```

**Stable vs experimental tests:** `base_url` (dev or prod app) is independent of the test image. By default callers use `e2e_tests_channel: prod` and pull `latest` from the **prod** Artifact Registry (built from `e2e-tests` `main`). Set `e2e_tests_channel: develop` (repo var `E2E_TESTS_CHANNEL` in `app`) to validate in-flight test changes from the **dev** registry (built from `e2e-tests` `develop`).

```yaml
# app — opt into experimental tests while still hitting dev URL
with:
  base_url: https://app.dev.neuraltrust.ai
  e2e_tests_channel: develop   # or vars.E2E_TESTS_CHANNEL=develop
  image_tag: latest
```

### Runners

| Runner | Use case |
|--------|----------|
| `ubuntu-latest` (default) | Public/Twingate URLs — connects via Twingate before tests |
| `arc-runner-medium` | In-cluster URLs (k8s service DNS) — Twingate disabled automatically |

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `service` | Yes | — | Playwright service name (`app`, `trustgate`, `admin-console`, `data-plane`) |
| `base_url` | Yes | — | Base URL of the service under test |
| `expected_version` | No | — | Commit SHA expected in health endpoint (empty = skip version gate) |
| `health_path` | No | `/api/health` | Health check path for version polling |
| `e2e_tests_channel` | No | `prod` | `prod` = stable tests (prod registry) · `develop` = experimental tests (dev registry) |
| `image_tag` | No | `latest` | `e2e-tests` image tag in Artifact Registry |
| `runner` | No | `ubuntu-latest` | GitHub Actions runner label |
| `twingate_enabled` | No | `true` | Connect Twingate before tests (ignored on ARC runners) |
| `grep` | No | — | Playwright `--grep` filter (empty = service default) |
| `allure_project` | No | `service` | Allure `project_id` |
| `e2e_run_enabled` | No | `true` | Run tests (`false` = list only) |
| `version_wait_minutes` | No | `20` | Health gate timeout in minutes |
| `dev_gcp_project_id` | No | inferred | Dev GCP project ID for the `develop` e2e-tests image channel (falls back to parsing the dev service account email) |
| `prod_gcp_project_id` | No | inferred | Prod GCP project ID for the `prod` e2e-tests image channel (falls back to parsing the prod service account email) |
| `allure_public_url` | No | `https://allure.internal.neuraltrust.ai` | Public Allure URL shown in summaries and used by public runners |
| `allure_internal_url` | No | `http://allure-api.allure.svc.cluster.local:5050` | Internal Allure URL used by ARC runners |
| `e2e_vars_json` | No | `{}` | JSON map of non-secret `E2E_*` variables (login paths, team selectors, workspace names, etc.) |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `ALLURE_USER` | Yes | Allure server credentials |
| `ALLURE_PASS` | Yes | Allure server credentials |
| `PROD_WIF_PROVIDER` | No* | GCP WIF for prod registry (stable tests) |
| `PROD_WIF_SERVICE_ACCOUNT` | No* | GCP service account email |
| `DEV_WIF_PROVIDER` | No* | GCP WIF for dev registry (experimental tests) |
| `DEV_WIF_SERVICE_ACCOUNT` | No* | GCP service account email |
| `WIF_PROVIDER` / `WIF_SERVICE_ACCOUNT` | No | Deprecated fallback when channel-specific WIF is omitted |
| `TWINGATE_SERVICE_KEY` | No | Twingate service key (public runners) |
| `E2E_SECRETS_JSON` | No | JSON map of `E2E_*` env vars (overrides individual secrets) |
| `E2E_USER`, `E2E_PASSWORD`, etc. | No | Individual E2E credentials when not using `E2E_SECRETS_JSON` |

Pass non-secret service-specific E2E settings via `e2e_vars_json`; pass credentials through `E2E_SECRETS_JSON` or the individual E2E secrets.

---

## Docker Image Scanning

Container images are scanned with **Trivy** via [`image-scan.yml`](#image-scan-reusable-workflow). Deploy and release workflows call it automatically; you can also invoke it standalone.

### Scan modes

| Pipeline stage | Mode | Blocks? | What is scanned |
|----------------|------|---------|-----------------|
| **Dev deploy** (`docker-build-deploy.yml`, `multi-image-deploy.yml`) | Warn (`exit_code: 0`) | No | Image just pushed to dev registry |
| **Prod release** (`release-promote.yml`, `multi-image-release-promote.yml`) | Block (`exit_code: 1`) | Yes | Dev source (promote) or rebuilt prod image (hotfix) |

Both modes scan for **CRITICAL,HIGH** severity and count only **fixable** CVEs (`ignore_unfixed: true`).

### Image Scan (reusable workflow)

**`image-scan.yml`** — Pulls an image from Artifact Registry, scans OS packages and application dependencies, and optionally uploads SARIF to the GitHub Security tab.

Findings are **always printed as a table in the job log** and the blocking gate lives there (`exit_code`), so a blocked promote always shows *which* CVEs caused it. SARIF upload is best-effort: it needs `security-events: write` + `actions: read` **and** code scanning enabled on the repo; where that's missing it logs `Code Security must be enabled` and is skipped without failing the scan.

```yaml
jobs:
  scan:
    uses: NeuralTrust/workflows/.github/workflows/image-scan.yml@main
    permissions:
      contents: read
      id-token: write
      security-events: write   # required for SARIF upload
      actions: read            # required for SARIF upload on private repos
    with:
      image_ref: europe-west1-docker.pkg.dev/my-proj/nt-docker/my-svc:abc123
      exit_code: '1'           # '0' = warn, '1' = block
    secrets:
      WIF_PROVIDER: ${{ secrets.DEV_WIF_PROVIDER }}
      WIF_SERVICE_ACCOUNT: ${{ secrets.DEV_WIF_SERVICE_ACCOUNT }}
```

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `image_ref` | — | Full image reference including registry, project, repo, and tag |
| `severity` | `CRITICAL,HIGH` | Severity levels to scan |
| `exit_code` | `0` | `0` = warn (never blocks), `1` = block on findings |
| `ignore_unfixed` | `true` | Only count vulnerabilities with a fix available |
| `scanners` | `vuln` | Trivy scanners (`vuln` only by default; avoids secret false positives in dependency test fixtures) |
| `trivyignore_path` | *(auto)* | Path to `.trivyignore`; auto-detected from repo root if present |
| `upload_sarif` | `true` | Upload SARIF to GitHub Security tab |
| `registry` | `europe-west1-docker.pkg.dev` | Registry host for docker login |

### Suppressing false positives

Image scans use `scanners: vuln` by default so prod gates block only on fixable CVEs, not Trivy secret hits in third-party packages (e.g. masked tokens in `trusttest` dataset YAML). Repository secret detection stays in `sast.yml` / Gitleaks.

Add a `.trivyignore` file at the repo root (same convention as `sast.yml`) to suppress accepted CVE findings. Both deploy and release scans auto-detect it.

---

## Slack Notifications

Deploy and release workflows send Slack notifications on success or failure.

**Smart release notifications** include the strategy used:
- "promoted from dev" (for develop→main releases)
- "rebuilt (hotfix)" (for direct pushes)
- "Blocked by image scan" (fixable CRITICAL/HIGH CVEs found — see Security tab)

To enable:

1. Create a [Slack Incoming Webhook](https://api.slack.com/messaging/webhooks)
2. Add it as an **organization secret**: `SLACK_WEBHOOK_URL`
3. Callers using `secrets: inherit` get notifications automatically

If the secret is not set, the notification step is silently skipped.

---

## Dependabot

All repos include a `dependabot.yml` that creates automated PRs for dependency updates:

| Ecosystem | Schedule | Behavior |
|-----------|----------|----------|
| `github-actions` | Weekly (Monday) | Updates action versions |
| `docker` | Weekly (Monday) | Updates base image versions |
| `gomod` / `pip` / `npm` | Weekly (Monday) | Groups minor+patch updates, ignores major |

PRs target the `develop` branch only. Since all changes must be tested before promotion to `main`, dependency updates follow the same flow: merged into `develop` → tested → promoted via PR to `main`. Dependabot PRs trigger the standard CI pipeline (tests + SAST/security + metadata validation), so safe updates follow the same review path as other changes.

---

## Repository Self-Protection ("CI of CIs")

Because every repo in the org consumes these reusable workflows and composite
actions, a mistake here breaks pipelines org-wide. This repo therefore guards
its own Actions surface:

| Feature | File | What it does |
|---------|------|--------------|
| **Dependabot** | [`.github/dependabot.yml`](.github/dependabot.yml) | Weekly `github-actions` updates across `.github/workflows/**` and `.github/actions/**`. Minor/patch grouped into one PR. |
| **Workflows CI** | [`.github/workflows/workflows-ci.yml`](.github/workflows/workflows-ci.yml) | Runs on any change to `.github/**`. **actionlint** (blocking) catches broken syntax/shell; **zizmor** (informational) audits for Actions security issues and uploads SARIF to the Security tab. |
| **OpenSSF Scorecard** | [`.github/workflows/scorecard.yml`](.github/workflows/scorecard.yml) | Scheduled supply-chain posture check (branch protection, token scopes, pinned deps, dangerous patterns) → Security tab. |
| **CODEOWNERS** | [`.github/CODEOWNERS`](.github/CODEOWNERS) | Requires owner review for changes under `.github/` when branch protection enforces it. |
| **zizmor policy** | [`.github/zizmor.yml`](.github/zizmor.yml) | Accepts release-tag (`ref-pin`) pins so intentional `@vN` pins maintained by Dependabot are not flagged as `unpinned-uses`. |

**zizmor posture:** matching the SAST workflow (`Trivy` blocks, other scanners
are informational), zizmor is non-blocking for now and surfaces findings in the
Security tab. There is a backlog of `template-injection` findings in the legacy
deploy workflows (`${{ inputs.* }}` / `${{ github.ref_name }}` interpolated
directly into `run:` blocks); once those are moved to `env:` vars, flip the
zizmor step to blocking by adding a `uvx zizmor --min-severity high .` gate.

**To enable the gates fully** (recommended), turn on branch protection for
`main` with: require PR review, require "Workflows CI" status check, and require
review from Code Owners.

---

## Setup Guide

### Automated Setup

Run the setup script to configure all GCP and GitHub infrastructure in one go:

```bash
cd workflows
chmod +x setup-pipeline.sh
./setup-pipeline.sh
```

The script handles:
1. GCP Workload Identity Federation (WIF) pools and OIDC providers for dev and prod
2. GCP Service Accounts with Artifact Registry writer permissions
3. Cross-project read access (prod SA → dev registry) for the image promote strategy
4. GitHub org-level variables (`DEV_GCP_PROJECT_ID`, `PROD_GCP_PROJECT_ID`)
5. GitHub org-level secrets (WIF providers, service accounts, tokens)

Prerequisites: `gcloud`, `gh`, and `jq` must be installed and authenticated.

### Required Secrets & Variables

**Organization-level variables (not sensitive):**

| Name | Description |
|------|-------------|
| `DEV_GCP_PROJECT_ID` | Dev GCP project ID (source registry for promote, target for dev deploys) |
| `PROD_GCP_PROJECT_ID` | Prod GCP project ID (target for releases) |

**Organization-level secrets:**

| Name | What it is | Why it's needed |
|------|-----------|-----------------|
| `DEV_WIF_PROVIDER` | GCP WIF provider path (dev project) | Authenticates dev deployments to GCP. Format: `projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>` |
| `DEV_WIF_SERVICE_ACCOUNT` | GCP SA email (dev project) | Identity for dev deployments. Format: `<SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com` |
| `PROD_WIF_PROVIDER` | GCP WIF provider path (prod project) | Authenticates prod releases to GCP. Same format as above |
| `PROD_WIF_SERVICE_ACCOUNT` | GCP SA email (prod project) | Identity for prod releases. Same format as above |
| `GH_TOKEN` | GitHub **PAT** with `contents: write` | Single PAT for creating releases, pushing kustomization/changelog commits, and private Go module access. Must be a PAT (not `GITHUB_TOKEN`) so release events can trigger downstream workflows |
| `OPENAI_API_KEY` | OpenAI API key | Powers AI semver bump |
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL *(optional)* | Deploy/release/smoke-test notifications. Can be overridden per-repo with a repo-level secret for different Slack channels |

> **Note:** Callers explicitly reference the correct org secret by name — `deploy.yml` uses `DEV_*` secrets, `release.yml` uses `PROD_*` secrets. The reusable workflows accept generic `WIF_PROVIDER` / `WIF_SERVICE_ACCOUNT` inputs and are unchanged.

**Per-repo secrets (only where needed):**

| Secret | Description |
|--------|-------------|
| `HUGGINGFACE_TOKEN` | HuggingFace model downloads (repos that use HF models) |
| `GOOGLE_API_KEY` | Google API access for tests (repos that need it) |
| `SLACK_WEBHOOK_URL` | Overrides the org-level webhook for per-repo Slack channels |

**IAM requirements (for promote strategy):**

The prod WIF service account needs **read** access to the dev Artifact Registry:

```bash
gcloud artifacts repositories add-iam-policy-binding nt-docker \
  --project=<DEV_GCP_PROJECT_ID> \
  --location=europe-west1 \
  --member="serviceAccount:<PROD_WIF_SA_EMAIL>" \
  --role="roles/artifactregistry.reader"
```

> Run `./setup-pipeline.sh` from the workflows repo to automate the full WIF + secrets setup.

### Workflow Behavior Summary

| Trigger | Docker Tags | Image Scan | Kustomization | config.env | Environment |
|---------|-------------|------------|---------------|------------|-------------|
| Push `develop` | `COMMIT_SHA`, `latest`, `cache` | Warn (non-blocking) | `k8s/overlays/dev` | `APPLICATION_VERSION=<sha>` | Dev |
| PR to `main` | — (no build) | — | — | — | — (CI only) |
| Push `main` | — (no build) | — | — | — | — (creates release) |
| GitHub Release (promote) | `v1.2.3`, `SHA`, `latest`, `cache` | Block (dev source) | `k8s/overlays/prod` | `APPLICATION_VERSION=v1.2.3` | Prod |
| GitHub Release (rebuild) | `v1.2.3`, `SHA`, `latest`, `cache` | Block (prod image) | `k8s/overlays/prod` | `APPLICATION_VERSION=v1.2.3` | Prod |

---

## Composite Actions

| Action | Description |
|--------|-------------|
| [`docker-build-push`](.github/actions/docker-build-push/action.yml) | Build and push a Docker image (buildx) with shared tag/cache/secrets handling. Shared by all build/release workflows. |
| [`kustomize-set-images`](.github/actions/kustomize-set-images/action.yml) | Update image names/tags in `kustomization.yaml` via `kustomize edit set image` (pinned binary) instead of fragile `sed`. |
| [`git-commit-push`](.github/actions/git-commit-push/action.yml) | Commit selected paths and push with `pull --rebase` + retry to avoid overlay-update races. Outputs the pushed commit SHA. |
| [`free-disk-space`](.github/actions/free-disk-space/action.yml) | Free runner disk space for large Docker builds. |
| [`setup-crane`](.github/actions/setup-crane/action.yml) | Install a pinned `crane` binary for image promotion (`crane copy`). |
| [`setup-kreuzberg`](.github/actions/setup-kreuzberg/action.yml) | Install Kreuzberg FFI + Tesseract OCR for Go CGO builds. Used by `tests.yml` when `kreuzberg_enabled: true`. |
