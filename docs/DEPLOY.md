# DiskHealth — VPS Deployment Guide

This walks you through standing up the central server on **AWS Lightsail** and
deploying the agent to your first device. Total time: ~30–45 minutes.

The same steps work on any Ubuntu VPS (Hetzner, DO, etc.) — only the
provisioning section is Lightsail-specific.

---

## 0. Prerequisites

- A domain you control (e.g. `example.com`) so you can create a DNS record like
  `disk-health.example.com`. Required for automatic HTTPS.
- Your DiskHealth repo pushed to GitHub (so devices can `git clone` it).
  **Edit the `REPO_GIT` default** in
  [mint-token.sh](../server/scripts/mint-token.sh) to your fork's clone URL,
  e.g. `https://github.com/youruser/DiskHealth.git`.
- **Tag a release** (e.g. `v1.0.0`) so devices pin with `git checkout v1.0.0`
  instead of tracking `main`. See [§7](#7-cutting-a-release-pinned-installs).

---

## 1. Provision the Lightsail instance

1. AWS console → **Lightsail** → **Create instance**.
2. Platform **Linux/Unix**, blueprint **OS Only → Ubuntu 22.04 LTS**.
3. Plan: **$12/mo (2 GB RAM, 2 vCPU, 60 GB SSD)**. (First 3 months free.)
4. Name it `diskhealth` and create.

### Static IP (so devices always find it)
- Lightsail → **Networking** → **Create static IP** → attach to the instance.
- Note the IP.

### Firewall
On the instance's **Networking** tab, ensure these IPv4 rules exist:
| Application | Protocol | Port |
|---|---|---|
| SSH | TCP | 22 |
| HTTP | TCP | 80 |
| HTTPS | TCP | 443 |

Do **not** open 8086/3000/8080 — those stay internal to Docker.

### DNS
At your DNS provider, create an **A record**:
`disk-health.example.com → <your static IP>`. Wait for it to resolve
(`dig +short disk-health.example.com` should return your IP).

### Automatic snapshots (your backup for historical data)
Lightsail → instance → **Snapshots** → enable **Automatic snapshots**. This is
what protects your history if the instance disk dies.

---

## 2. Install Docker on the instance

SSH in (Lightsail browser SSH, or `ssh ubuntu@<ip>` with your key), then:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu      # log out/in afterwards to use docker w/o sudo
```

Verify: `docker compose version`.

---

## 3. Deploy the server stack

```bash
git clone https://github.com/youruser/DiskHealth.git
cd DiskHealth/server

# --- configure ---
cp .env.example .env
# Generate strong secrets:
echo "INFLUX_TOKEN=$(openssl rand -hex 32)"
echo "INFLUX_PASSWORD=$(openssl rand -hex 16)"
echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)"
nano .env    # paste those in, set DOMAIN and ACME_EMAIL

# tokens.json must exist before first boot (it's bind-mounted)
echo '{}' > ingest/tokens.json

# --- launch ---
docker compose up -d --build
docker compose ps          # all services should be "running"
docker compose logs -f caddy   # watch it obtain the TLS cert, then Ctrl-C
```

Caddy fetches a Let's Encrypt cert automatically once DNS points at the box and
ports 80/443 are reachable. If the cert doesn't issue, re-check DNS + firewall.

### Smoke-test the ingest endpoint
```bash
curl https://disk-health.example.com/ingest/health
# => {"status":"ok","devices_configured":0}
```

### Log into Grafana
Browse to `https://disk-health.example.com/` and log in with
`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`. The **DiskHealth → Fleet
Overview** dashboard and the InfluxDB datasource are already provisioned.

---

## 4. Mint a token and deploy to a device

On the **server**, from `DiskHealth/server`:

```bash
./scripts/mint-token.sh warehouse-pc-01
```

It registers the token (hot-reloaded by the ingest service, no restart needed)
and prints a ready-to-run command. On the **target Ubuntu device**, clone the
repo and run the installer locally:

```bash
git clone https://github.com/youruser/DiskHealth.git
cd DiskHealth
git checkout v1.0.0        # pin to a release tag
sudo ./install.sh \
    --endpoint https://disk-health.example.com \
    --token tok_xxxxxxxxxxxxxxxxxxxxxxxx
```

> Run from a checkout, the installer uses the `getdiskhealth.sh` sitting next to
> it — no download, integrity provided by git. (If you ever pipe `install.sh`
> straight from a URL instead, it falls back to fetching the collector from the
> pinned release and verifying its SHA256.) Mint-token.sh prints this command.

The installer:
1. installs `smartmontools`, `jq`, `curl`;
2. drops `/opt/disk-health/getdiskhealth.sh` (from the local checkout);
3. writes `/etc/disk-health/config` (mode 600) with the endpoint + token;
4. registers `/etc/cron.d/disk-health` at a **randomized minute** around 02:00;
5. runs one collection immediately and reports success.

> Prefer a different hour? Add `--hour 4`. Skip the immediate run with `--no-run`.

Confirm on the server:
```bash
curl https://disk-health.example.com/ingest/health   # devices_configured: 1
```
Within a few seconds the disk should appear in the Grafana dashboard.

Repeat `mint-token.sh <device-id>` per device — each gets its own revocable token.

---

## 5. Failure-prediction alerts (recommended)

The starter dashboard plots the leading indicators. To get **notified**, add
Grafana alert rules (Alerting → Alert rules → New). High-signal conditions:

| Metric (field on `disk_smart`) | Alert when | Meaning |
|---|---|---|
| `smart_passed` | `== 0` | Drive's own overall self-assessment FAILED — replace now |
| `reallocated_sector_ct` | increasing / `> 0` and rising | Bad sectors being remapped |
| `current_pending_sector` | `> 0` | Unreadable sectors awaiting reallocation — strong failure signal |
| `offline_uncorrectable` | `> 0` | Uncorrectable sectors |
| `udma_crc_error_count` | rising | Cable/connection problems |
| `nvme_percentage_used` | `> 90` | SSD near end of rated write life |
| `nvme_available_spare` | `< nvme_available_spare_threshold` | NVMe spare blocks exhausted |
| `media_errors` | `> 0` and rising | NVMe media errors |
| `temperature_c` | `> 60` sustained | Thermal stress |

Point the alerts at a contact point (email/Slack/webhook) under Alerting →
Contact points.

---

## 6. Day-2 operations

**Revoke a device:** edit `server/ingest/tokens.json`, delete that token's line.
The ingest service hot-reloads; the device's next POST gets `403` and spools
locally (harmless). To also stop it collecting, on the device:
`sudo rm /etc/cron.d/disk-health`.

**Rotate a device token:** mint a new one, re-run the installer on the device
(it overwrites the config), then remove the old token from `tokens.json`.

**Update the parsing logic:** edit [server/ingest/app.py](../server/ingest/app.py),
then `docker compose up -d --build ingest`. No device changes needed.

**Update the collector on the fleet:** cut a new release (below), then on each
device `cd DiskHealth && git pull && git checkout v1.0.1 && sudo ./install.sh
--endpoint ... --token ...`. The installer overwrites the collector and cron in
place; the existing config is re-supplied via the same flags.

**Backups:** Lightsail automatic snapshots cover everything (Influx data lives
in the `influxdb-data` Docker volume on the instance disk). For off-box backups,
`docker compose exec influxdb influx backup /tmp/backup` and copy it off.

**Retention:** set `INFLUX_RETENTION` in `.env` before first boot (`0s` = keep
forever). To change later, adjust the bucket's retention in the InfluxDB UI or
via `influx bucket update`.

---

## 7. Cutting a release (pinned installs)

Devices pin with `git checkout v1.0.0`, so cut a release tag whenever
`getdiskhealth.sh` changes. From the repo root:

```bash
./scripts/cut-release.sh v1.0.0
```

This stamps the tag into [mint-token.sh](../server/scripts/mint-token.sh) and
records `getdiskhealth.sh`'s SHA256 in [install.sh](../install.sh) (the hash is
only used by the curl-pipe fallback; the git-clone path trusts the checkout).
Then commit and tag:

```bash
git add -A
git commit -m "Release v1.0.0"
git tag v1.0.0
git push origin main v1.0.0
```

From now on, `mint-token.sh` prints install commands pinned to `v1.0.0`. To ship
a change, bump the version (`v1.0.1`), re-run `cut-release.sh`, and re-tag.

**Hardening that pairs with this:** enable repo **2FA**, **branch protection**
on `main`, and **tag protection** so tags can't be moved. Pinning + hash
verification means even a compromised `main` can't push code to your fleet — but
protected tags stop an attacker from re-pointing `v1.0.0` itself.

> Need to override at install time? `--ref <tag>`, `--repo-base <url>`, and
> `--sha256 <hash>` flags exist for one-off testing.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Cert won't issue | DNS A record correct? Ports 80/443 open? `docker compose logs caddy` |
| `unknown token` (403) | Token present in `ingest/tokens.json`? File valid JSON? |
| Device: "no internal disks detected" | RAID/virtual disks may need a `smartctl -d` type; check `lsblk -dn -o NAME,TYPE,TRAN,RM` |
| Nothing in Grafana | `docker compose logs ingest`; confirm `/ingest/health` reachable from the device |
| Device offline at night | Payloads spool in `/var/lib/disk-health/spool` and flush next run |

Device-side logs: `/var/log/disk-health.log`. Run a manual collection any time
with `sudo /opt/disk-health/getdiskhealth.sh`.
