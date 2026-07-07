#!/usr/bin/env bash
#
# mint-token.sh — create a per-device bearer token, register it, and print the
# ready-to-run install one-liner for that device.
#
# Run on the server, from the server/ directory:
#   ./scripts/mint-token.sh <device-id>
#
# Example:
#   ./scripts/mint-token.sh warehouse-pc-01

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOKENS_FILE="$HERE/ingest/tokens.json"
ENV_FILE="$HERE/.env"

DEVICE_ID="${1:-}"
[[ -n "$DEVICE_ID" ]] || { echo "Usage: $0 <device-id>" >&2; exit 1; }

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

# Domain for the printed install command (read from .env if present).
DOMAIN="disk-health.example.com"
if [[ -f "$ENV_FILE" ]]; then
  DOMAIN="$(grep -E '^DOMAIN=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  DOMAIN="${DOMAIN:-disk-health.example.com}"
fi

# Your fork's clone URL and the tag to pin devices to (git checkout).
# Override either in the environment if needed.
REPO_GIT="${REPO_GIT:-https://github.com/YOURORG/DiskHealth.git}"
REF="${REF:-v1.0.0}"

[[ -f "$TOKENS_FILE" ]] || echo '{}' > "$TOKENS_FILE"

# Reject duplicate device-id to avoid two tokens silently writing as one device.
if jq -e --arg id "$DEVICE_ID" 'to_entries | any(.value.device_id == $id)' \
     "$TOKENS_FILE" >/dev/null; then
  echo "A token for device-id '$DEVICE_ID' already exists. Revoke it first." >&2
  exit 1
fi

TOKEN="tok_$(openssl rand -hex 24)"

tmp="$(mktemp)"
jq --arg t "$TOKEN" --arg id "$DEVICE_ID" \
   '. + {($t): {device_id: $id}}' "$TOKENS_FILE" > "$tmp"
mv "$tmp" "$TOKENS_FILE"

# tokens.json is mounted read-only into the ingest container, which hot-reloads
# on mtime change — no restart needed.

cat <<EOF

Minted token for device '$DEVICE_ID'.

Run this on the target Ubuntu device:

  git clone $REPO_GIT
  cd DiskHealth && git checkout $REF
  sudo ./install.sh \\
      --endpoint https://$DOMAIN \\
      --token $TOKEN

EOF
