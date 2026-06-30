"""
DiskHealth ingest service.

Accepts nightly SMART payloads from devices, authenticates them with a
per-device bearer token, normalizes the raw smartctl JSON into InfluxDB points,
and writes them.

Trust model: the device's identity (`device_id`) comes from the token mapping,
NOT from the request body. A device can report its hostname (informational) but
cannot spoof which device_id its data is filed under.

Normalization lives here on purpose, so parsing logic can evolve without
redeploying the fleet.
"""
import calendar
import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from influxdb_client import InfluxDBClient, Point, WritePrecision
from influxdb_client.client.write_api import SYNCHRONOUS

INFLUX_URL = os.environ["INFLUX_URL"]
INFLUX_ORG = os.environ["INFLUX_ORG"]
INFLUX_BUCKET = os.environ["INFLUX_BUCKET"]
INFLUX_TOKEN = os.environ["INFLUX_TOKEN"]
TOKENS_FILE = os.environ.get("TOKENS_FILE", "/data/tokens.json")

app = FastAPI(title="DiskHealth ingest")

_influx = InfluxDBClient(url=INFLUX_URL, token=INFLUX_TOKEN, org=INFLUX_ORG)
_write = _influx.write_api(write_options=SYNCHRONOUS)

# --- token loading (hot-reloaded when tokens.json changes) --------------------
_tokens_cache: dict = {}
_tokens_mtime: float = 0.0


def load_tokens() -> dict:
    """Return {token: {"device_id": ...}}, reloading if the file changed."""
    global _tokens_cache, _tokens_mtime
    try:
        mtime = os.path.getmtime(TOKENS_FILE)
    except OSError:
        return _tokens_cache
    if mtime != _tokens_mtime:
        try:
            _tokens_cache = json.loads(Path(TOKENS_FILE).read_text() or "{}")
            _tokens_mtime = mtime
        except (OSError, json.JSONDecodeError):
            pass
    return _tokens_cache


def device_for_token(token: str) -> str | None:
    entry = load_tokens().get(token)
    return entry.get("device_id") if entry else None


# --- SMART attribute IDs worth tracking for failure prediction ----------------
# (ATA). Raw value is what trends toward failure.
ATA_ATTRS = {
    5: "reallocated_sector_ct",
    9: "power_on_hours",
    10: "spin_retry_count",
    177: "wear_leveling_count",
    184: "end_to_end_error",
    187: "reported_uncorrect",
    188: "command_timeout",
    196: "reallocated_event_count",
    197: "current_pending_sector",
    198: "offline_uncorrectable",
    199: "udma_crc_error_count",
    231: "ssd_life_left",
    233: "media_wearout_indicator",
}


def _to_float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def normalize_disk(disk: dict) -> tuple[dict, dict, list[dict]]:
    """
    Returns (tags, fields, attributes) extracted from one disk's smartctl JSON.

    - tags/fields -> 'disk_smart' measurement (curated, cross-bus)
    - attributes  -> list of per-attribute rows for 'smart_attribute' measurement
    """
    path = disk.get("path", "")
    s = disk.get("smartctl", {}) or {}

    tags = {
        "path": path,
        "model": s.get("model_name") or s.get("scsi_model_name") or "unknown",
        "serial": s.get("serial_number") or "unknown",
    }
    fields: dict = {}
    attributes: list[dict] = []

    # device type / bus
    dev = s.get("device", {}) or {}
    tags["type"] = dev.get("type") or "unknown"

    # capacity
    cap = (s.get("user_capacity") or {}).get("bytes")
    if cap is not None:
        fields["capacity_bytes"] = float(cap)

    # firmware (field, not tag — avoids churn)
    if s.get("firmware_version"):
        fields["firmware"] = s["firmware_version"]

    # overall health
    passed = (s.get("smart_status") or {}).get("passed")
    if passed is not None:
        fields["smart_passed"] = 1.0 if passed else 0.0

    # temperature (smartctl normalizes to Celsius)
    temp = (s.get("temperature") or {}).get("current")
    if temp is not None:
        fields["temperature_c"] = float(temp)

    # power-on hours / cycles
    poh = (s.get("power_on_time") or {}).get("hours")
    if poh is not None:
        fields["power_on_hours"] = float(poh)
    pcc = s.get("power_cycle_count")
    if pcc is not None:
        fields["power_cycle_count"] = float(pcc)

    # --- ATA attribute table --------------------------------------------------
    table = (s.get("ata_smart_attributes") or {}).get("table") or []
    for attr in table:
        aid = attr.get("id")
        name = attr.get("name", f"attr_{aid}")
        raw = _to_float((attr.get("raw") or {}).get("value"))
        norm = _to_float(attr.get("value"))
        worst = _to_float(attr.get("worst"))
        thresh = _to_float(attr.get("thresh"))
        attributes.append(
            {
                "attr_id": str(aid),
                "attr_name": name,
                "raw": raw,
                "value": norm,
                "worst": worst,
                "thresh": thresh,
            }
        )
        # promote the key ones into curated fields
        if aid in ATA_ATTRS and raw is not None:
            fields[ATA_ATTRS[aid]] = raw

    # --- NVMe health log ------------------------------------------------------
    nvme = s.get("nvme_smart_health_information_log") or {}
    if nvme:
        for src, dst in (
            ("percentage_used", "nvme_percentage_used"),
            ("available_spare", "nvme_available_spare"),
            ("available_spare_threshold", "nvme_available_spare_threshold"),
            ("media_errors", "media_errors"),
            ("critical_warning", "nvme_critical_warning"),
            ("unsafe_shutdowns", "unsafe_shutdowns"),
            ("data_units_written", "data_units_written"),
            ("data_units_read", "data_units_read"),
            ("controller_busy_time", "nvme_controller_busy_time"),
        ):
            val = _to_float(nvme.get(src))
            if val is not None:
                fields[dst] = val
        # NVMe carries power-on hours here too if the top-level was absent
        if "power_on_hours" not in fields:
            val = _to_float(nvme.get("power_on_hours"))
            if val is not None:
                fields["power_on_hours"] = val

    return tags, fields, attributes


@app.get("/ingest/health")
def health():
    return {"status": "ok", "devices_configured": len(load_tokens())}


@app.post("/ingest")
async def ingest(request: Request, authorization: str = Header(default="")):
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization[len("Bearer "):].strip()
    device_id = device_for_token(token)
    if not device_id:
        raise HTTPException(status_code=403, detail="unknown token")

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid JSON")

    hostname = str(body.get("hostname", "unknown"))
    machine_id = str(body.get("machine_id", "unknown"))
    disks = body.get("disks") or []
    if not isinstance(disks, list) or not disks:
        raise HTTPException(status_code=400, detail="no disks in payload")

    # Use the device's collection timestamp so historical re-sends (from the
    # spool) land at the right point in time.
    ts = body.get("collected_at")
    ts_ns = None
    if isinstance(ts, str):
        try:
            # collected_at is UTC ("...Z"); timegm interprets the struct as UTC.
            ts_ns = calendar.timegm(
                time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
            ) * 1_000_000_000
        except ValueError:
            ts_ns = None

    points: list[Point] = []
    disk_count = 0
    for disk in disks:
        if not isinstance(disk, dict):
            continue
        tags, fields, attributes = normalize_disk(disk)
        if not fields:
            continue
        disk_count += 1

        p = Point("disk_smart").tag("device_id", device_id).tag("host", hostname)
        p.tag("machine_id", machine_id)
        for k, v in tags.items():
            p.tag(k, str(v))
        for k, v in fields.items():
            p.field(k, v)
        if ts_ns is not None:
            p.time(ts_ns, WritePrecision.NS)
        points.append(p)

        for a in attributes:
            ap = (
                Point("smart_attribute")
                .tag("device_id", device_id)
                .tag("host", hostname)
                .tag("serial", str(tags.get("serial", "unknown")))
                .tag("attr_id", a["attr_id"])
                .tag("attr_name", a["attr_name"])
            )
            for fld in ("raw", "value", "worst", "thresh"):
                if a[fld] is not None:
                    ap.field(fld, a[fld])
            if ts_ns is not None:
                ap.time(ts_ns, WritePrecision.NS)
            points.append(ap)

    if not points:
        raise HTTPException(status_code=400, detail="no usable SMART data")

    try:
        _write.write(bucket=INFLUX_BUCKET, org=INFLUX_ORG, record=points)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"influx write failed: {e}")

    return {"status": "ok", "device_id": device_id, "disks": disk_count}
