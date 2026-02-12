#!/usr/bin/env bash
# =============================================================================
# NeuralTrust — Pipeline Infrastructure Setup
# =============================================================================
# One-time setup script for the GitHub Actions CI/CD pipeline infrastructure.
#
# This script configures:
#   1. GCP Workload Identity Federation (WIF) for dev and prod
#   2. GCP Service Accounts with Artifact Registry permissions
#   3. Cross-project read access (prod SA → dev registry) for image promote
#   4. GitHub org variables and secrets
#
# Prerequisites:
#   - gcloud CLI authenticated with owner/admin access to both GCP projects
#   - gh CLI authenticated with admin access to NeuralTrust org
#   - jq installed
#
# Usage:
#   chmod +x setup-pipeline.sh
#   ./setup-pipeline.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROD_GCP_PROJECT_ID="${PROD_GCP_PROJECT_ID:-}"
DEV_GCP_PROJECT_ID="${DEV_GCP_PROJECT_ID:-}"
GH_ORG="${GH_ORG:-NeuralTrust}"
AR_LOCATION="${AR_LOCATION:-europe-west1}"
AR_REPO="${AR_REPO:-nt-docker}"
AR_PYTHON_REPO="${AR_PYTHON_REPO:-nt-python}"
WIF_POOL="github-actions"
WIF_PROVIDER="github"
SA_NAME="github-actions"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
header()  { echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
header "Pre-flight checks"

for cmd in gcloud gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd is not installed. Please install it first."
    exit 1
  fi
  success "$cmd found"
done

# Verify gcloud auth
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 | grep -q '@'; then
  error "gcloud is not authenticated. Run: gcloud auth login"
  exit 1
fi
success "gcloud authenticated as $(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"

# Verify gh auth
if ! gh auth status &>/dev/null; then
  error "gh CLI is not authenticated. Run: gh auth login"
  exit 1
fi
success "gh CLI authenticated"

# ---------------------------------------------------------------------------
# Prompt for required configuration (if not set via env vars)
# ---------------------------------------------------------------------------
header "Configuration"

if [ -z "$PROD_GCP_PROJECT_ID" ]; then
  read -rp "$(echo -e "${BLUE}[INPUT]${NC} Production GCP Project ID: ")" PROD_GCP_PROJECT_ID
  if [ -z "$PROD_GCP_PROJECT_ID" ]; then
    error "Production GCP Project ID is required."
    exit 1
  fi
fi
success "Prod GCP Project: $PROD_GCP_PROJECT_ID"

if [ -z "$DEV_GCP_PROJECT_ID" ]; then
  read -rp "$(echo -e "${BLUE}[INPUT]${NC} Development GCP Project ID: ")" DEV_GCP_PROJECT_ID
  if [ -z "$DEV_GCP_PROJECT_ID" ]; then
    error "Development GCP Project ID is required."
    exit 1
  fi
fi
success "Dev GCP Project:  $DEV_GCP_PROJECT_ID"

info "GitHub Org:        $GH_ORG"
info "AR Location:       $AR_LOCATION"
info "AR Docker Repo:    $AR_REPO"
info "AR Python Repo:    $AR_PYTHON_REPO"

# ---------------------------------------------------------------------------
# Resolve project numbers
# ---------------------------------------------------------------------------
header "Resolving GCP project numbers"

PROD_PROJECT_NUMBER=$(gcloud projects describe "$PROD_GCP_PROJECT_ID" --format="value(projectNumber)" 2>/dev/null) || {
  error "Cannot access project $PROD_GCP_PROJECT_ID. Check permissions."
  exit 1
}
success "PROD project number: $PROD_PROJECT_NUMBER"

DEV_PROJECT_NUMBER=$(gcloud projects describe "$DEV_GCP_PROJECT_ID" --format="value(projectNumber)" 2>/dev/null) || {
  error "Cannot access project $DEV_GCP_PROJECT_ID. Check permissions."
  exit 1
}
success "DEV project number:  $DEV_PROJECT_NUMBER"

# =============================================================================
# Phase 0.1 — GCP: Workload Identity Federation
# =============================================================================

setup_wif() {
  local PROJECT_ID="$1"
  local ENV_LABEL="$2"

  header "WIF Setup — $ENV_LABEL ($PROJECT_ID)"

  # Step 1: Create Workload Identity Pool
  info "Creating Workload Identity Pool '$WIF_POOL'..."
  if gcloud iam workload-identity-pools describe "$WIF_POOL" \
      --project="$PROJECT_ID" --location="global" &>/dev/null; then
    warn "Pool '$WIF_POOL' already exists in $PROJECT_ID — skipping"
  else
    gcloud iam workload-identity-pools create "$WIF_POOL" \
      --project="$PROJECT_ID" \
      --location="global" \
      --display-name="GitHub Actions"
    success "Pool '$WIF_POOL' created in $PROJECT_ID"
  fi

  # Step 2: Create OIDC Provider
  info "Creating OIDC provider '$WIF_PROVIDER'..."
  if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
      --project="$PROJECT_ID" --location="global" \
      --workload-identity-pool="$WIF_POOL" &>/dev/null; then
    warn "Provider '$WIF_PROVIDER' already exists in $PROJECT_ID — skipping"
  else
    gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
      --project="$PROJECT_ID" \
      --location="global" \
      --workload-identity-pool="$WIF_POOL" \
      --display-name="GitHub" \
      --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
      --attribute-condition="assertion.repository_owner == '$GH_ORG'" \
      --issuer-uri="https://token.actions.githubusercontent.com"
    success "Provider '$WIF_PROVIDER' created in $PROJECT_ID"
  fi

  # Step 3: Create Service Account
  local SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  info "Creating service account '$SA_NAME'..."
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    warn "Service account '$SA_EMAIL' already exists — skipping"
  else
    gcloud iam service-accounts create "$SA_NAME" \
      --project="$PROJECT_ID" \
      --display-name="GitHub Actions CI/CD"
    success "Service account '$SA_EMAIL' created"
  fi

  # Step 4: Grant Artifact Registry writer (Docker + Python repos)
  info "Granting Artifact Registry writer to $SA_EMAIL on $AR_REPO (Docker)..."
  gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
    --project="$PROJECT_ID" \
    --location="$AR_LOCATION" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/artifactregistry.writer" \
    --quiet 2>/dev/null || true
  success "Artifact Registry writer granted on $AR_REPO"

  info "Granting Artifact Registry writer to $SA_EMAIL on $AR_PYTHON_REPO (Python)..."
  gcloud artifacts repositories add-iam-policy-binding "$AR_PYTHON_REPO" \
    --project="$PROJECT_ID" \
    --location="$AR_LOCATION" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/artifactregistry.writer" \
    --quiet 2>/dev/null || true
  success "Artifact Registry writer granted on $AR_PYTHON_REPO"

  # Step 5: Allow GitHub Actions to impersonate the SA
  local PROJECT_NUMBER
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
  info "Binding workloadIdentityUser for $GH_ORG..."
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository_owner/${GH_ORG}" \
    --quiet 2>/dev/null || true
  success "Workload Identity User binding created"
}

# Run WIF setup for both environments
setup_wif "$PROD_GCP_PROJECT_ID" "PROD"
setup_wif "$DEV_GCP_PROJECT_ID" "DEV"

# =============================================================================
# Phase 0.2 — GCP: Cross-project read access (promote strategy)
# =============================================================================
header "Cross-project access — Prod SA reads Dev registry"

PROD_SA_EMAIL="${SA_NAME}@${PROD_GCP_PROJECT_ID}.iam.gserviceaccount.com"

info "Granting Artifact Registry reader on dev registry to prod SA..."
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
  --project="$DEV_GCP_PROJECT_ID" \
  --location="$AR_LOCATION" \
  --member="serviceAccount:$PROD_SA_EMAIL" \
  --role="roles/artifactregistry.reader" \
  --quiet 2>/dev/null || true
success "Prod SA can now read dev registry (for crane copy / image promote)"

# =============================================================================
# Phase 0.3 — Resolve WIF Provider paths
# =============================================================================
header "Resolving WIF Provider paths"

DEV_WIF_PROVIDER_PATH=$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
  --project="$DEV_GCP_PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$WIF_POOL" \
  --format="value(name)" 2>/dev/null) || {
  error "Cannot resolve DEV WIF provider path"
  exit 1
}
success "DEV_WIF_PROVIDER: $DEV_WIF_PROVIDER_PATH"

PROD_WIF_PROVIDER_PATH=$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
  --project="$PROD_GCP_PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$WIF_POOL" \
  --format="value(name)" 2>/dev/null) || {
  error "Cannot resolve PROD WIF provider path"
  exit 1
}
success "PROD_WIF_PROVIDER: $PROD_WIF_PROVIDER_PATH"

DEV_SA_EMAIL="${SA_NAME}@${DEV_GCP_PROJECT_ID}.iam.gserviceaccount.com"

# =============================================================================
# Phase 0.4 — GitHub: Org variables and secrets
# =============================================================================
header "GitHub Org Variables"

info "Setting DEV_GCP_PROJECT_ID..."
gh variable set DEV_GCP_PROJECT_ID --body "$DEV_GCP_PROJECT_ID" --org "$GH_ORG" 2>/dev/null && \
  success "DEV_GCP_PROJECT_ID = $DEV_GCP_PROJECT_ID" || \
  warn "Failed to set DEV_GCP_PROJECT_ID (may need admin permissions)"

info "Setting PROD_GCP_PROJECT_ID..."
gh variable set PROD_GCP_PROJECT_ID --body "$PROD_GCP_PROJECT_ID" --org "$GH_ORG" 2>/dev/null && \
  success "PROD_GCP_PROJECT_ID = $PROD_GCP_PROJECT_ID" || \
  warn "Failed to set PROD_GCP_PROJECT_ID (may need admin permissions)"

# ---------------------------------------------------------------------------
header "GitHub Org Secrets — GCP WIF"

info "Setting DEV_WIF_PROVIDER..."
gh secret set DEV_WIF_PROVIDER --body "$DEV_WIF_PROVIDER_PATH" --org "$GH_ORG" 2>/dev/null && \
  success "DEV_WIF_PROVIDER set" || \
  warn "Failed to set DEV_WIF_PROVIDER"

info "Setting DEV_WIF_SERVICE_ACCOUNT..."
gh secret set DEV_WIF_SERVICE_ACCOUNT --body "$DEV_SA_EMAIL" --org "$GH_ORG" 2>/dev/null && \
  success "DEV_WIF_SERVICE_ACCOUNT = $DEV_SA_EMAIL" || \
  warn "Failed to set DEV_WIF_SERVICE_ACCOUNT"

info "Setting PROD_WIF_PROVIDER..."
gh secret set PROD_WIF_PROVIDER --body "$PROD_WIF_PROVIDER_PATH" --org "$GH_ORG" 2>/dev/null && \
  success "PROD_WIF_PROVIDER set" || \
  warn "Failed to set PROD_WIF_PROVIDER"

info "Setting PROD_WIF_SERVICE_ACCOUNT..."
gh secret set PROD_WIF_SERVICE_ACCOUNT --body "$PROD_SA_EMAIL" --org "$GH_ORG" 2>/dev/null && \
  success "PROD_WIF_SERVICE_ACCOUNT = $PROD_SA_EMAIL" || \
  warn "Failed to set PROD_WIF_SERVICE_ACCOUNT"

# ---------------------------------------------------------------------------
header "GitHub Org Secrets — Tokens (interactive)"

echo ""
echo "The following secrets require manual input. Press Enter to skip any."
echo ""

# GH_TOKEN
read -rsp "$(echo -e "${YELLOW}Enter GH_TOKEN (GitHub PAT with contents:write + pull_requests:write):${NC} ")" GH_TOKEN_VALUE
echo ""
if [ -n "$GH_TOKEN_VALUE" ]; then
  gh secret set GH_TOKEN --body "$GH_TOKEN_VALUE" --org "$GH_ORG" 2>/dev/null && \
    success "GH_TOKEN set" || warn "Failed to set GH_TOKEN"
else
  warn "GH_TOKEN skipped — set manually later"
fi

# OPENAI_API_KEY
read -rsp "$(echo -e "${YELLOW}Enter OPENAI_API_KEY:${NC} ")" OPENAI_KEY_VALUE
echo ""
if [ -n "$OPENAI_KEY_VALUE" ]; then
  gh secret set OPENAI_API_KEY --body "$OPENAI_KEY_VALUE" --org "$GH_ORG" 2>/dev/null && \
    success "OPENAI_API_KEY set" || warn "Failed to set OPENAI_API_KEY"
else
  warn "OPENAI_API_KEY skipped — set manually later"
fi

# SLACK_WEBHOOK_URL
read -rsp "$(echo -e "${YELLOW}Enter SLACK_WEBHOOK_URL (optional, press Enter to skip):${NC} ")" SLACK_URL_VALUE
echo ""
if [ -n "$SLACK_URL_VALUE" ]; then
  gh secret set SLACK_WEBHOOK_URL --body "$SLACK_URL_VALUE" --org "$GH_ORG" 2>/dev/null && \
    success "SLACK_WEBHOOK_URL set" || warn "Failed to set SLACK_WEBHOOK_URL"
else
  warn "SLACK_WEBHOOK_URL skipped — set manually later"
fi

# =============================================================================
# Summary
# =============================================================================
header "Setup Complete"

echo ""
echo -e "  ${GREEN}GCP Projects${NC}"
echo -e "    PROD: $PROD_GCP_PROJECT_ID (number: $PROD_PROJECT_NUMBER)"
echo -e "    DEV:  $DEV_GCP_PROJECT_ID (number: $DEV_PROJECT_NUMBER)"
echo ""
echo -e "  ${GREEN}WIF Provider Paths${NC}"
echo -e "    DEV:  $DEV_WIF_PROVIDER_PATH"
echo -e "    PROD: $PROD_WIF_PROVIDER_PATH"
echo ""
echo -e "  ${GREEN}Service Accounts${NC}"
echo -e "    DEV:  $DEV_SA_EMAIL"
echo -e "    PROD: $PROD_SA_EMAIL"
echo ""
echo -e "  ${GREEN}GitHub Org Variables${NC}"
echo "    DEV_GCP_PROJECT_ID  = $DEV_GCP_PROJECT_ID"
echo "    PROD_GCP_PROJECT_ID = $PROD_GCP_PROJECT_ID"
echo ""
echo -e "  ${GREEN}GitHub Org Secrets${NC}"
echo "    DEV_WIF_PROVIDER"
echo "    DEV_WIF_SERVICE_ACCOUNT"
echo "    PROD_WIF_PROVIDER"
echo "    PROD_WIF_SERVICE_ACCOUNT"
echo "    GH_TOKEN"
echo "    OPENAI_API_KEY"
echo "    SLACK_WEBHOOK_URL"
echo ""
echo -e "  ${GREEN}Cross-project access${NC}"
echo "    Prod SA → dev registry (artifactregistry.reader)"
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE} Copy-paste commands to set GitHub org variables & secrets manually${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}# --- Org Variables ---${NC}"
echo "gh variable set DEV_GCP_PROJECT_ID --body \"$DEV_GCP_PROJECT_ID\" --org $GH_ORG"
echo "gh variable set PROD_GCP_PROJECT_ID --body \"$PROD_GCP_PROJECT_ID\" --org $GH_ORG"
echo ""
echo -e "${GREEN}# --- Org Secrets: GCP WIF ---${NC}"
echo "gh secret set DEV_WIF_PROVIDER --body \"$DEV_WIF_PROVIDER_PATH\" --org $GH_ORG"
echo "gh secret set DEV_WIF_SERVICE_ACCOUNT --body \"$DEV_SA_EMAIL\" --org $GH_ORG"
echo "gh secret set PROD_WIF_PROVIDER --body \"$PROD_WIF_PROVIDER_PATH\" --org $GH_ORG"
echo "gh secret set PROD_WIF_SERVICE_ACCOUNT --body \"$PROD_SA_EMAIL\" --org $GH_ORG"
echo ""
echo -e "${GREEN}# --- Org Secrets: Tokens (replace <VALUE> with actual values) ---${NC}"
echo "gh secret set GH_TOKEN --body \"<YOUR_GITHUB_PAT>\" --org $GH_ORG"
echo "gh secret set OPENAI_API_KEY --body \"<YOUR_OPENAI_KEY>\" --org $GH_ORG"
echo "gh secret set SLACK_WEBHOOK_URL --body \"<YOUR_SLACK_WEBHOOK>\" --org $GH_ORG"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Run the commands above in a terminal with org admin permissions"
echo "  2. Push the shared workflows repo (NeuralTrust/workflows)"
echo "  3. Add per-repo secrets as needed (see README.md → Setup Guide)"
echo "  4. Verify with a test deploy + promote flow"
echo ""
