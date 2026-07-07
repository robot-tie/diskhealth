#!/usr/bin/env bash
#
# install.sh — installer for the DiskHealth collection agent.
#
# Primary (recommended) usage — clone the repo and run locally:
#
#   git clone https://github.com/YOURORG/DiskHealth.git
#   cd DiskHealth              # optional: git checkout v1.0.0 to pin
#   sudo ./install.sh --endpoint https://disk-health.example.com --token tok_xxxx
#
# When run from a checkout it installs the getdiskhealth.sh sitting next to it —
# no download, integrity provided by git.
#
# Fallback usage — curl-pipe (no local copy present). It then fetches the
# collector from the pinned release and verifies its SHA256:
#
#   curl -fsSL https://raw.githubusercontent.com/YOURORG/DiskHealth/v1.0.0/install.sh \
#     | sudo bash -s -- --endpoint https://... --token tok_xxxx
#
# Either way it installs dependencies, drops the collector, writes the device
# config (with the per-device bearer token), and registers a nightly cron job at
# a randomized minute so fleets don't all post at once.

set -euo pipefail

# --- fallback (curl-pipe) settings; unused when run from a checkout -----------
# Immutable release ref the collector is pulled from. Override with --ref.
REF="${REF:-v1.0.0}"
# Base raw URL of your fork (no trailing ref). Override with --repo-base.
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/YOURORG/DiskHealth}"
# Expected SHA256 of getdiskhealth.sh for this release. Stamped by
# scripts/cut-release.sh. Override at install time with --sha256.
EXPECTED_SHA256="${EXPECTED_SHA256:-REPLACE_WITH_SHA256}"

# Directory this script lives in (empty when piped via curl).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

ENDPOINT=""
TOKEN=""
HOUR=2            # default nightly hour (local time)
RUN_NOW=1

usage() {
  cat <<EOF
Usage: install.sh --endpoint URL --token TOKEN [options]

  --endpoint URL    Central ingest base URL (e.g. https://disk-health.example.com)
  --token TOKEN     Per-device bearer token (mint one on the server)
  --hour N          Nightly run hour, 0-23 local time (default: 2)
  --ref REF         Release tag/commit to fetch the collector from (default: $REF)
  --repo-base URL   Base raw URL of your fork (no ref)
  --sha256 HASH     Expected SHA256 of getdiskhealth.sh (overrides built-in)
  --no-run          Do not run a collection immediately after install
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)  ENDPOINT="$2"; shift 2;;
    --token)     TOKEN="$2"; shift 2;;
    --hour)      HOUR="$2"; shift 2;;
    --ref)       REF="$2"; shift 2;;
    --repo-base) REPO_BASE="$2"; shift 2;;
    --sha256)    EXPECTED_SHA256="$2"; shift 2;;
    --no-run)    RUN_NOW=0; shift;;
    -h|--help)   usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Please run as root (use sudo)." >&2; exit 1; }
[[ -n "$ENDPOINT" ]] || { echo "--endpoint is required" >&2; exit 1; }
[[ -n "$TOKEN" ]] || { echo "--token is required" >&2; exit 1; }
ENDPOINT="${ENDPOINT%/}"   # strip trailing slash

echo "==> Installing dependencies (smartmontools, jq, curl)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq smartmontools jq curl >/dev/null

echo "==> Creating directories"
install -d -m 755 /opt/disk-health
install -d -m 700 /etc/disk-health
install -d -m 700 /var/lib/disk-health/spool

LOCAL_COLLECTOR="${SCRIPT_DIR:+$SCRIPT_DIR/getdiskhealth.sh}"

if [[ -n "$LOCAL_COLLECTOR" && -f "$LOCAL_COLLECTOR" ]]; then
  # --- primary path: install the collector from this checkout ----------------
  echo "==> Installing collector from local checkout"
  install -m 755 "$LOCAL_COLLECTOR" /opt/disk-health/getdiskhealth.sh
else
  # --- fallback path: fetch from the pinned release and verify SHA256 --------
  REPO_RAW="$REPO_BASE/$REF"
  TMP_COLLECTOR="$(mktemp)"
  trap 'rm -f "$TMP_COLLECTOR"' EXIT

  echo "==> No local copy found; fetching collector ($REF)"
  if ! curl -fsSL "$REPO_RAW/getdiskhealth.sh" -o "$TMP_COLLECTOR"; then
    echo "Failed to download getdiskhealth.sh from $REPO_RAW" >&2
    exit 1
  fi

  echo "==> Verifying integrity"
  ACTUAL_SHA256="$(sha256sum "$TMP_COLLECTOR" | awk '{print $1}')"
  if [[ "$EXPECTED_SHA256" == "REPLACE_WITH_SHA256" || -z "$EXPECTED_SHA256" ]]; then
    echo "    WARNING: no expected SHA256 configured — skipping integrity check."
    echo "             Stamp one with scripts/cut-release.sh or pass --sha256."
  elif [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "!! Integrity check FAILED for getdiskhealth.sh" >&2
    echo "   expected: $EXPECTED_SHA256" >&2
    echo "   actual:   $ACTUAL_SHA256" >&2
    echo "   Refusing to install a collector that doesn't match the pinned release." >&2
    exit 1
  else
    echo "    sha256 verified ($ACTUAL_SHA256)"
  fi

  install -m 755 "$TMP_COLLECTOR" /opt/disk-health/getdiskhealth.sh
fi

echo "==> Writing device config"
umask 077
cat > /etc/disk-health/config <<EOF
# DiskHealth device config — generated by install.sh on $(date -u +%FT%TZ)
ENDPOINT="$ENDPOINT"
TOKEN="$TOKEN"
EOF
chmod 600 /etc/disk-health/config

echo "==> Registering nightly cron job"
MIN=$(( RANDOM % 60 ))   # randomize minute to avoid a fleet-wide thundering herd
cat > /etc/cron.d/disk-health <<EOF
# DiskHealth nightly collection — managed by install.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$MIN $HOUR * * * root /opt/disk-health/getdiskhealth.sh >> /var/log/disk-health.log 2>&1
EOF
chmod 644 /etc/cron.d/disk-health
echo "    scheduled daily at ${HOUR}:$(printf '%02d' "$MIN") (local time)"

if [[ "$RUN_NOW" -eq 1 ]]; then
  echo "==> Running an initial collection now"
  if /opt/disk-health/getdiskhealth.sh; then
    echo "==> Success. DiskHealth agent installed and reporting."
  else
    echo "!! Initial run failed (see output above). The cron job is still installed;"
    echo "   payloads will be spooled and retried. Check ENDPOINT/TOKEN reachability."
    exit 1
  fi
else
  echo "==> Installed. First report will run tonight."
fi
