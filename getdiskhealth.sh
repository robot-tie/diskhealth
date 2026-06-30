#!/usr/bin/env bash
#
# getdiskhealth.sh — collect SMART health for all internal disks and POST it
# to the central DiskHealth ingest endpoint.
#
# Deployed to /opt/disk-health/getdiskhealth.sh by install.sh and run nightly
# from /etc/cron.d/disk-health as root (smartctl requires root).
#
# Config is read from /etc/disk-health/config:
#     ENDPOINT="https://disk-health.example.com"
#     TOKEN="tok_xxxxxxxx"
#
# Design note: this script intentionally stays "dumb". It ships the raw
# smartctl JSON for every disk to the server, which does all normalization.
# That way the metric/parsing logic lives in one place (the ingest service)
# and can be updated without redeploying every device.

set -uo pipefail

CONFIG_FILE="${DISKHEALTH_CONFIG:-/etc/disk-health/config}"
SPOOL_DIR="${DISKHEALTH_SPOOL:-/var/lib/disk-health/spool}"
MAX_SPOOL_FILES=60   # keep at most ~2 months of failed nights, then drop oldest

log() { printf '%s diskhealth: %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (smartctl needs root)"
[[ -r "$CONFIG_FILE" ]] || die "config not found/readable: $CONFIG_FILE"
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${ENDPOINT:?ENDPOINT not set in config}"
: "${TOKEN:?TOKEN not set in config}"

for bin in smartctl jq curl lsblk; do
  command -v "$bin" >/dev/null 2>&1 || die "missing dependency: $bin"
done

mkdir -p "$SPOOL_DIR"

# --- enumerate internal disks --------------------------------------------------
# Include real disks only; exclude USB, removable media, and read-only/optical.
# TRAN may be empty for virtio/RAID-backed disks — we still attempt those.
mapfile -t DISKS < <(
  lsblk -dn -o NAME,TYPE,TRAN,RM 2>/dev/null | awk '
    $2 == "disk" && $4 == "0" && $3 != "usb" { print $1 }
  '
)

[[ ${#DISKS[@]} -gt 0 ]] || die "no internal disks detected"

# --- collect smartctl JSON per disk -------------------------------------------
disks_json='[]'
for name in "${DISKS[@]}"; do
  dev="/dev/$name"
  # smartctl exit code is a bitmask; a non-zero code does NOT mean "no data".
  # We capture stdout regardless and only skip if it isn't valid JSON.
  raw="$(smartctl -j -a -d auto "$dev" 2>/dev/null)"
  if ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
    log "skip $dev: smartctl produced no parseable JSON"
    continue
  fi
  disks_json="$(jq -c --argjson d "$raw" --arg path "$dev" \
    '. + [{path:$path, smartctl:$d}]' <<<"$disks_json")"
  log "collected $dev"
done

if [[ "$(jq 'length' <<<"$disks_json")" -eq 0 ]]; then
  die "no disks yielded SMART data"
fi

machine_id="$(cat /etc/machine-id 2>/dev/null || echo unknown)"
payload="$(jq -n \
  --arg hn "$(hostname -f 2>/dev/null || hostname)" \
  --arg mid "$machine_id" \
  --arg ts "$(date -u +%FT%TZ)" \
  --argjson disks "$disks_json" \
  '{hostname:$hn, machine_id:$mid, collected_at:$ts, disks:$disks}')"

# --- POST helper ---------------------------------------------------------------
post_payload() {
  # $1 = JSON string; returns 0 on success
  curl -fsS --max-time 30 -X POST "$ENDPOINT/ingest" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- >/dev/null 2>&1 <<<"$1"
}

# --- flush any previously spooled (failed) payloads first ----------------------
shopt -s nullglob
for f in $(ls -1tr "$SPOOL_DIR"/*.json 2>/dev/null); do
  if post_payload "$(cat "$f")"; then
    rm -f "$f"
    log "flushed spooled $f"
  else
    log "still offline; keeping spooled $f"
    break   # network down; stop trying, keep order
  fi
done

# --- send tonight's payload ----------------------------------------------------
if post_payload "$payload"; then
  log "posted $(jq 'length' <<<"$disks_json") disk(s) to $ENDPOINT"
else
  spool_file="$SPOOL_DIR/$(date -u +%Y%m%dT%H%M%SZ).json"
  printf '%s' "$payload" > "$spool_file"
  chmod 600 "$spool_file"
  log "POST failed; spooled to $spool_file"
  # trim oldest if spool grows unbounded
  mapfile -t spooled < <(ls -1tr "$SPOOL_DIR"/*.json 2>/dev/null)
  if (( ${#spooled[@]} > MAX_SPOOL_FILES )); then
    drop=$(( ${#spooled[@]} - MAX_SPOOL_FILES ))
    for ((i=0; i<drop; i++)); do rm -f "${spooled[$i]}"; done
    log "trimmed $drop old spooled payload(s)"
  fi
  exit 1
fi
