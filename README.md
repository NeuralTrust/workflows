# NeuralTrust Shared Workflows

Reusable GitHub Actions workflows for the NeuralTrust organization.

## Pipeline Architecture

Every repo follows the same standardized pipeline:

```
┌──────────────┐     ┌────────────────────────────────────────────────────────────────┐
│ Push develop │────▶│ deploy.yml → build + image scan + kustomize + Slack notify     │──▶ Dev
└──────────────┘     └────────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────────────────────────┐
│ PR → main    │────▶│ ci.yml → AI Review + Tests + SAST + Gosec + Auto-Approve     │
└──────────────┘     └──────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────────────┐
│ Push main    │────▶│ auto-release.yml → AI Semver Bump → GitHub Release│
└──────────────┘     └────────────────────────┬─────────────────────────┘
                                              │ triggers
                    ┌─────────────────────────▼──────────────────────────────────────┐
                    │ release.yml → Smart Release (promote or rebuild)               │
                    │                                                                │
                    │   develop→main PR?  ──YES──▶  PROMOTE (crane copy, ~10s)       │──▶ Prod
                    │   hotfix/direct?    ──YES──▶  REBUILD (docker build)           │──▶ Prod
                    └────────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────────────────────────────────────────┐
│ Weekly       │────▶│ Dependabot → dependency update PRs (auto)        │
└──────────────┘     └──────────────────────────────────────────────────┘
```

### Workflows Per Repo

| File | Trigger | What it does |
|------|---------|-------------|
| `deploy.yml` | Push to `develop` | Build with COMMIT_SHA → deploy to dev |
| `ci.yml` | PR to `main` | AI code review + Tests + SAST/security + auto-approve |
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
| [`dast.yml`](#dast) | OWASP ZAP scan of running app (APIs/frontend); JWT or login-based auth |
| [`seo-check.yml`](#seo-static-audit) | Static Next.js SEO audit (metadata, sitemap/robots presence); job summary |
| [`seo-live-url.yml`](#seo-live-url) | Live site: homepage / `robots.txt` / sitemap content audit + Lighthouse SEO |
| [`ai-code-review.yml`](#ai-code-review) | AI-powered PR code review with inline comments |
| [`auto-approve.yml`](#auto-approve) | Auto-approve PR when all CI checks pass |
| [`ai-release-bump.yml`](#ai-release-bump) | AI-powered semver classification + GitHub Release creation |

### Post-Deploy

| Workflow | Description |
|----------|-------------|
| [`smoke-test.yml`](#smoke-test) | Post-deploy health check with version polling |

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
| develop → main PR merged | **Promote** | ~10 seconds | Copies the tested dev image to prod (byte-identical) |
| Hotfix / direct push to main | **Rebuild** | ~2-5 minutes | Full Docker build in the prod registry |

### How detection works

1. Queries the GitHub API for PRs associated with the release commit
2. If a merged PR from `develop` → `main` is found:
   - Gets the develop branch tip SHA from the PR
   - Verifies the dev image exists in the dev registry (by commit SHA)
   - If found → **promote** (crane copy)
   - If not found → falls back to **rebuild**
3. If no develop→main PR → **rebuild** (hotfix path)

### Benefits of promote

- **Zero build time** — image copy takes ~10 seconds vs minutes for a full build
- **Byte-identical binary** — what was tested in dev is exactly what runs in prod
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

Detection runs once; each image is promoted (or rebuilt) in parallel via a matrix job.

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

### Outputs

| Output | Description |
|--------|-------------|
| `new_version` | The new version tag (e.g., `v1.2.3`) |
| `bump_type` | The bump type (`major`, `minor`, `patch`) |
| `previous_version` | The previous version tag |

> **Important:** `GH_TOKEN` must be a PAT (not `GITHUB_TOKEN`) so the created release event can trigger other workflows.

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
| `coverage_enabled` | No | `false` | Generate coverage report in job summary |
| `coverage_file` | No | `coverage.txt` | Coverage file path |
| `working_directory` | No | `.` | Working directory for all commands |
| `setup_commands` | No | — | Commands to run before tests (e.g., install deps, copy env files) |
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

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `trivy_severity` | `CRITICAL,HIGH` | Severity levels to scan |
| `trivy_exit_code` | `1` | Exit code on findings (`1`=fail, `0`=warn) |
| `scan_type` | `fs` | Trivy scan type (`fs`, `config`, `repo`) |
| `gitleaks_enabled` | `true` | Enable secret detection |
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
3. Scans the image with Trivy (CRITICAL,HIGH, warn mode)
4. Updates `kustomization.yaml` (image tag) and `config.env` (`APPLICATION_VERSION`)
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
│ PR → main    │────▶│ ci.yml → AI Review + Lint + SAST + Auto-Approve      │
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

## AI Code Review

**`ai-code-review.yml`** — Reviews PR diffs using OpenAI, posts inline comments.

```yaml
jobs:
  review:
    uses: NeuralTrust/workflows/.github/workflows/ai-code-review.yml@main
    secrets:
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

---

## Auto Approve

**`auto-approve.yml`** — Waits for all CI checks to pass, then auto-approves the PR.

```yaml
jobs:
  approve:
    uses: NeuralTrust/workflows/.github/workflows/auto-approve.yml@main
    secrets:
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
```

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

## Docker Image Scanning

Both build and release workflows automatically scan the pushed image with **Trivy**:

- Scans for `CRITICAL,HIGH` severity vulnerabilities
- Runs in warn mode (exit code 0) — does not block deployments
- Results shown in the GitHub Actions job summary

No additional configuration needed — image scanning is always enabled.

---

## Slack Notifications

Deploy and release workflows send Slack notifications on success or failure.

**Smart release notifications** include the strategy used:
- "promoted from dev" (for develop→main releases)
- "rebuilt (hotfix)" (for direct pushes)

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

PRs target the `develop` branch only. Since all changes must be tested before promotion to `main`, dependency updates follow the same flow: merged into `develop` → tested → promoted via PR to `main`. Dependabot PRs trigger the standard CI pipeline (AI review + tests + SAST + auto-approve), so safe updates are merged automatically.

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
| `GH_TOKEN` | GitHub **PAT** with `contents: write` + `pull_requests: write` | Single PAT for all GitHub operations: creating releases, pushing kustomization commits, AI code review comments, PR approvals, and private Go module access. Must be a PAT (not `GITHUB_TOKEN`) so release events can trigger downstream workflows |
| `OPENAI_API_KEY` | OpenAI API key | Powers AI code review and AI semver bump |
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

| Trigger | Docker Tags | Kustomization | config.env | Environment |
|---------|-------------|---------------|------------|-------------|
| Push `develop` | `COMMIT_SHA`, `latest`, `cache` | `k8s/overlays/dev` | `APPLICATION_VERSION=<sha>` | Dev |
| PR to `main` | — (no build) | — | — | — (CI only) |
| Push `main` | — (no build) | — | — | — (creates release) |
| GitHub Release (promote) | `v1.2.3`, `SHA`, `latest`, `cache` | `k8s/overlays/prod` | `APPLICATION_VERSION=v1.2.3` | Prod |
| GitHub Release (rebuild) | `v1.2.3`, `SHA`, `latest`, `cache` | `k8s/overlays/prod` | `APPLICATION_VERSION=v1.2.3` | Prod |

---

## Composite Actions

| Action | Description |
|--------|-------------|
| [`setup-kreuzberg`](.github/actions/setup-kreuzberg/action.yml) | Install Kreuzberg FFI + Tesseract OCR for Go CGO builds. Used by `tests.yml` when `kreuzberg_enabled: true`. |
