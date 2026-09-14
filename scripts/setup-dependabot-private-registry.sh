#!/usr/bin/env bash
# =============================================================================
# NeuralTrust — Dependabot access to private Go modules (org-level)
# =============================================================================
# Most Go services import private modules — event-schemas/gen/go,
# TrustGuard/pkg/metrics, TrustGate/pkg/metrics, TrustLens/pkg/inventory,
# agentguardian-api. Those are not on the public Go proxy, so an
# unauthenticated Dependabot cannot resolve the module graph. When that happens
# the whole `gomod` update job fails and Dependabot opens NO pull requests for
# that ecosystem — not weekly version bumps and not security fixes — while
# `docker` and `github-actions` updates keep flowing. A repo can sit like that
# for months while looking healthy.
#
# The fix is ONE organization-level Dependabot private registry of type
# `git_source` for https://github.com, authenticated with a read-only token
# that can reach every private module repo. Repos with access use it
# automatically; no `registries:` block is needed in any
# .github/dependabot.yml, so a repo that adopts a private module later is
# covered without touching its config.
#
#   docs: Giving security features access to private registries
#   api:  GET/POST/PATCH /orgs/{org}/private-registries
#
# The registry is looked up by (type, url), never by a stored name or ID, so
# re-running is safe: it updates in place if present, creates it otherwise.
# The token value is sealed with the org's private-registries public key
# (libsodium sealed box), which is a different key from the Actions and
# Dependabot secret stores — `gh secret set` cannot be used for this.
#
# Prerequisites:
#   - gh CLI authenticated as an org admin (admin:org scope)
#   - uv (https://docs.astral.sh/uv/) OR python3 with PyNaCl installed
#   - jq
#
# Usage:
#   ./scripts/setup-dependabot-private-registry.sh --token-env DEPENDABOT_PAT [options]
#
#   --token-env <VAR>       Env var holding the PAT to store (required).
#                           Do NOT name it GH_TOKEN: gh would then use that
#                           read-only PAT for this script's own admin calls
#                           too, and they would fail with 403.
#   --org <ORG>             GitHub org (default: NeuralTrust)
#   --visibility <V>        all | private | selected (default: all). `private`
#                           is least privilege when no public repo imports a
#                           private module.
#   --repos <A,B,C>         Repos for --visibility selected
#   --module-repos <A,B>    Private repos the token must be able to read; the
#                           script refuses to store a token that cannot.
#                           LegacyGateway is in the default set because
#                           LegacyGateway-EE reaches it through a `replace`
#                           onto the TrustGate module path.
#                           (default: event-schemas,TrustGuard,TrustLens,LegacyGateway,agentguardian-api)
#   --dry-run               Show what would change, change nothing
#
# Example:
#   read -s DEPENDABOT_PAT && export DEPENDABOT_PAT
#   ./scripts/setup-dependabot-private-registry.sh --token-env DEPENDABOT_PAT --dry-run
#   ./scripts/setup-dependabot-private-registry.sh --token-env DEPENDABOT_PAT
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

GH_ORG="${GH_ORG:-NeuralTrust}"
REGISTRY_URL="https://github.com"
REGISTRY_TYPE="git_source"
REGISTRY_USER="x-access-token"
VISIBILITY="all"
REPOS=""
MODULE_REPOS="event-schemas,TrustGuard,TrustLens,LegacyGateway,agentguardian-api"
TOKEN_ENV=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token-env)    TOKEN_ENV="$2"; shift 2 ;;
    --org)          GH_ORG="$2"; shift 2 ;;
    --visibility)   VISIBILITY="$2"; shift 2 ;;
    --repos)        REPOS="$2"; shift 2 ;;
    --module-repos) MODULE_REPOS="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      sed -n '3,58p' "$0"; exit 0 ;;
    *)              error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { error "$cmd is not installed."; exit 1; }
done

if command -v uv >/dev/null; then
  PY=(uv run --quiet --with pynacl python3)
elif python3 -c 'import nacl' 2>/dev/null; then
  PY=(python3)
else
  error "Need either uv or python3 with PyNaCl (pip install pynacl) to seal the token."
  exit 1
fi

if [[ -z "$TOKEN_ENV" ]]; then
  error "--token-env is required."
  echo "Put the PAT in an environment variable and pass its name, so the value" >&2
  echo "never lands in shell history or the process list." >&2
  exit 1
fi
TOKEN="${!TOKEN_ENV:-}"
[[ -n "$TOKEN" ]] || { error "\$$TOKEN_ENV is empty or unset."; exit 1; }

case "$VISIBILITY" in
  all|private) ;;
  selected) [[ -n "$REPOS" ]] || { error "--visibility selected needs --repos."; exit 1; } ;;
  *) error "--visibility must be all, private or selected."; exit 1 ;;
esac

info "Org:        $GH_ORG"
info "Registry:   $REGISTRY_TYPE $REGISTRY_URL (user $REGISTRY_USER)"
info "Visibility: $VISIBILITY${REPOS:+ → $REPOS}"
info "Verifying:  $MODULE_REPOS"
$DRY_RUN && warn "DRY RUN — nothing will be changed."
echo

# ---------------------------------------------------------------------------
# 1. The token must read every private module repo. A token that cannot is
#    worse than none: Dependabot fails identically but the setup looks done.
# ---------------------------------------------------------------------------
info "Checking token access to the private module repos..."
access_ok=true
IFS=',' read -ra MODULE_LIST <<< "$MODULE_REPOS"
for repo in "${MODULE_LIST[@]}"; do
  repo="$(echo "$repo" | xargs)"
  if GH_TOKEN="$TOKEN" gh api "repos/$GH_ORG/$repo" --silent 2>/dev/null; then
    success "$GH_ORG/$repo"
  else
    error "DENIED  $GH_ORG/$repo"
    access_ok=false
  fi
done
if [[ "$access_ok" != true ]]; then
  error "The token cannot read every private module repo — stopping."
  echo "Grant it read-only Contents + Metadata on the repos marked DENIED." >&2
  exit 1
fi
echo

# ---------------------------------------------------------------------------
# 2. Resolve the existing registry by (type, url) — no stored name or ID.
# ---------------------------------------------------------------------------
existing_name=$(gh api "orgs/$GH_ORG/private-registries" --paginate 2>/dev/null \
  | jq -r --arg t "$REGISTRY_TYPE" --arg u "$REGISTRY_URL" \
      '.configurations[]? | select(.registry_type==$t and .url==$u) | .name' | head -1)

if [[ -n "$existing_name" ]]; then
  warn "Registry already exists as '$existing_name' — it will be updated in place."
  method="PATCH"; endpoint="orgs/$GH_ORG/private-registries/$existing_name"
else
  info "No $REGISTRY_TYPE registry for $REGISTRY_URL yet — it will be created."
  method="POST";  endpoint="orgs/$GH_ORG/private-registries"
fi

# ---------------------------------------------------------------------------
# 3. Seal the token with the org's private-registries public key.
#    This key differs from the Actions and Dependabot secret-store keys.
# ---------------------------------------------------------------------------
pubkey_json=$(gh api "orgs/$GH_ORG/private-registries/public-key")
key_id=$(jq -r .key_id <<< "$pubkey_json")
key_b64=$(jq -r .key   <<< "$pubkey_json")

encrypted=$(PLAINTEXT="$TOKEN" PUBKEY="$key_b64" "${PY[@]}" - <<'PY'
import base64, os
from nacl import encoding, public
pk = public.PublicKey(os.environ["PUBKEY"].encode(), encoding.Base64Encoder())
sealed = public.SealedBox(pk).encrypt(os.environ["PLAINTEXT"].encode())
print(base64.b64encode(sealed).decode())
PY
)

# ---------------------------------------------------------------------------
# 4. Build the request body. selected_repository_ids are resolved from names
#    at apply time, so nothing environment-specific is written down.
# ---------------------------------------------------------------------------
body=$(jq -n \
  --arg type "$REGISTRY_TYPE" --arg url "$REGISTRY_URL" --arg user "$REGISTRY_USER" \
  --arg enc "$encrypted" --arg kid "$key_id" --arg vis "$VISIBILITY" \
  '{registry_type:$type, url:$url, username:$user, encrypted_value:$enc, key_id:$kid, visibility:$vis}')

if [[ "$VISIBILITY" == "selected" ]]; then
  ids=()
  IFS=',' read -ra REPO_LIST <<< "$REPOS"
  for repo in "${REPO_LIST[@]}"; do
    repo="$(echo "$repo" | xargs)"
    id=$(gh api "repos/$GH_ORG/$repo" -q .id 2>/dev/null) || { error "Repo not found: $GH_ORG/$repo"; exit 1; }
    ids+=("$id")
  done
  body=$(jq --argjson ids "$(printf '%s\n' "${ids[@]}" | jq -s .)" '. + {selected_repository_ids:$ids}' <<< "$body")
fi

if $DRY_RUN; then
  warn "Would $method $endpoint with:"
  jq 'del(.encrypted_value) + {encrypted_value:"<sealed>"}' <<< "$body"
  echo
  warn "Dry run complete."
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Apply.
# ---------------------------------------------------------------------------
result=$(gh api -X "$method" "$endpoint" --input - <<< "$body")
name=$(jq -r '.name // empty' <<< "$result")
if [[ -n "$name" ]]; then
  success "Registry '$name' ($method) — visibility=$VISIBILITY"
else
  success "Registry updated ($method) — visibility=$VISIBILITY"
fi
echo

info "Dependabot uses org-level registries automatically; no dependabot.yml change"
info "is needed. It picks this up on the next scheduled gomod run. To check sooner,"
info "open https://github.com/$GH_ORG/<repo>/network/updates and re-run the gomod job."
