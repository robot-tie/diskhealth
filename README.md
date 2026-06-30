# DiskHealth

Fleet-wide internal-disk SMART monitoring with centralized, historical storage
and failure-prediction dashboards. Devices on **any network** report nightly to
one central server over HTTPS, authenticated with a **per-device bearer token**.

```
 ┌────────────┐   nightly    ┌──────────────────────────── VPS ───────────────────────────┐
 │  Ubuntu    │  HTTPS POST  │  Caddy (TLS) ─┬─ /ingest ─▶ ingest (FastAPI) ─▶ InfluxDB    │
 │  device    │ ───────────▶ │   :443        └─ /*       ─▶ Grafana ◀──────────┘ (history) │
 │ smartctl   │  Bearer tok  │                                                              │
 └────────────┘              └──────────────────────────────────────────────────────────┘
```

## Repository layout

| Path | What it is |
|---|---|
| [getdiskhealth.sh](getdiskhealth.sh) | Device collector: enumerates internal disks, runs `smartctl`, POSTs raw JSON |
| [install.sh](install.sh) | One-line installer (curl-pipe): deps, config, nightly cron |
| [server/docker-compose.yml](server/docker-compose.yml) | The full server stack |
| [server/ingest/app.py](server/ingest/app.py) | Auth + normalization + InfluxDB writes |
| [server/Caddyfile](server/Caddyfile) | TLS termination + routing |
| [server/scripts/mint-token.sh](server/scripts/mint-token.sh) | Create a device token + print its install command |
| [server/grafana/](server/grafana/) | Provisioned datasource + starter dashboard |
| [docs/DEPLOY.md](docs/DEPLOY.md) | **Step-by-step VPS deployment guide** |

## Quick mental model

- **Devices stay dumb.** They ship raw `smartctl -j` output. All parsing /
  normalization happens in [the ingest service](server/ingest/app.py), so you
  can improve metric extraction by redeploying *one* container, not the fleet.
- **Identity is server-assigned.** A device's `device_id` comes from its token,
  not from anything it self-reports, so devices can't spoof each other.
- **Offline-safe.** If the network is down, the collector spools the night's
  payload locally and flushes it (with original timestamps) on the next run.

## Get started

See **[docs/DEPLOY.md](docs/DEPLOY.md)** for the complete walk-through:
provision the Lightsail box → bring up the stack → mint a token → deploy to a
device → verify → set up alerts and backups.
