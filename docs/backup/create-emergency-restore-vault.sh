#!/usr/bin/env bash
# ==============================================================================
# Package emergency restore credentials into an encrypted macOS .dmg
# ==============================================================================
# Canonical offline store for NeuralTrust git backup DR:
#   - backup-emergency-reader.json (GCP SA key, read-only on backup bucket)
#   - emergency-restore-procedure.md (runbook)
#   - README.txt (bucket, project, pointers)
#
# Store the .dmg on a FileVault-enabled Mac or team-shared secure storage.
# Store the .dmg password in Apple Passwords (shared secure note, 2+ responders).
# Never commit the .dmg, JSON key, or password to git/Slack/email.
#
# Usage:
#   export PROJECT_ID=neuraltrust-git-backup
#   export BUCKET=nt-git-backups
#   ./create-emergency-restore-vault.sh ~/Desktop/neuraltrust-git-backup-vault.dmg
# ==============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID}"
BUCKET="${BUCKET:?Set BUCKET}"
DMG_PATH="${1:?Usage: $0 /path/to/neuraltrust-git-backup-vault.dmg}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: encrypted .dmg packaging requires macOS (hdiutil)."
  exit 1
fi

if [ -f "$DMG_PATH" ]; then
  echo "ERROR: Refusing to overwrite existing ${DMG_PATH}"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> Creating emergency reader SA key (temporary workspace only)"
"$SCRIPT_DIR/create-emergency-restore-sa.sh" "${work}/backup-emergency-reader.json"

cat > "${work}/README.txt" <<EOF
NeuralTrust — Git backup emergency restore vault
==============================================
GCP project: ${PROJECT_ID}
GCS bucket:  ${BUCKET}
Prefix:      git-backups/

Contents:
  - backup-emergency-reader.json  (offline read-only SA — rotate after use)
  - emergency-restore-procedure.md

.dmg password: Apple Passwords shared note (2+ incident responders).
EOF

cp "${SCRIPT_DIR}/emergency-restore-procedure.md" "${work}/"

size_mb=$(( $(du -sm "$work" | cut -f1) + 10 ))

echo "==> Choose a strong vault password (min 20 chars recommended)"
echo -n "Vault password: "
read -rs VAULT_PASS
echo
echo -n "Confirm password: "
read -rs VAULT_PASS_CONFIRM
echo
if [ "$VAULT_PASS" != "$VAULT_PASS_CONFIRM" ]; then
  echo "ERROR: Passwords do not match."
  exit 1
fi
if [ "${#VAULT_PASS}" -lt 12 ]; then
  echo "ERROR: Password too short (minimum 12 characters)."
  exit 1
fi

echo "==> Creating encrypted disk image (${size_mb} MB)"
printf '%s' "$VAULT_PASS" | hdiutil create \
  -size "${size_mb}m" \
  -fs HFS+J \
  -volname "NeuralTrust Git Backup" \
  -encryption AES-256 \
  -stdinpass \
  "$DMG_PATH"

echo "==> Copying vault contents into image"
mount_point="$(printf '%s' "$VAULT_PASS" | hdiutil attach "$DMG_PATH" -stdinpass -nobrowse | awk '/Apple_HFS/ {print $3}')"
cp "${work}/backup-emergency-reader.json" \
   "${work}/emergency-restore-procedure.md" \
   "${work}/README.txt" \
   "${mount_point}/"
sync
hdiutil detach "$mount_point"

shred -u "${work}/backup-emergency-reader.json" 2>/dev/null || rm -f "${work}/backup-emergency-reader.json"

echo ""
echo "==> Done: ${DMG_PATH}"
echo "    1. Copy .dmg to team secure storage (FileVault Mac / restricted share)."
echo "    2. Save the password in Apple Passwords (shared note, 2+ people)."
echo "    3. Delete any leftover JSON on disk. Verify with: hdiutil attach ${DMG_PATH}"
