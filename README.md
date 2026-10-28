# ente-cli

[![Build and Push to Docker Hub](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml)
[![Cleanup Docker Hub Tags](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml/badge.svg)](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml)

Minimal Alpine container for the [Ente CLI](https://github.com/ente-io/ente/tree/main/cli) with configurable loop or cron scheduling for automated exports.

Built from the latest upstream [`cli-v*`](https://github.com/ente-io/ente/releases) release tag via GitHub Actions and published to [Docker Hub](https://hub.docker.com/r/wittchy/ente-cli) for `linux/amd64` and `linux/arm64`.

## Features

- Static `ente-cli` binary built from a pinned `cli-v*` release (sparse checkout of `cli/` only)
- Digest-pinned base images and commit-SHA-pinned GitHub Actions, kept current by Dependabot
- Loop-based scheduled exports by default (runs as non-root `enteuser`)
- Optional Alpine BusyBox cron scheduling (configurable via env or a mounted crontab; exports still run as `enteuser`)
- Hardened Compose file: read-only root filesystem, minimal capabilities, `no-new-privileges`
- Timezone support via `TZ` + `tzdata`
- Optional Healthchecks.io-compatible success/failure pings
- Minimal image (Alpine + binary + BusyBox crond)
- No CGO dependencies

## Quick Start

```bash
# Create directories
mkdir -p cli-data data

# Start (uses compose.yaml in this repo)
docker compose up -d

# One-time login
docker exec -it -u enteuser ente-cli /usr/local/bin/ente-cli account add
```


Optional environment overrides for Compose:

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_TAG` | `latest` | Image tag |
| `SCHEDULER` | `loop` | `loop` or `cron` |
| `LOOP_INTERVAL` | `21600` | Seconds between loop exports |
| `CRON_SCHEDULE` | `0 */6 * * *` | Cron expression when `SCHEDULER=cron` |
| `CROND_LOG_LEVEL` | `8` | BusyBox `crond` verbosity (`8` quiet; `2`/`0` for debug) |
| `TZ` | `UTC` | Container timezone (affects cron local time + log timestamps) |
| `HEALTHCHECK_URL` | _(empty)_ | Push URL for Healthchecks.io / Uptime Kuma / similar |
| `HEALTHCHECK_PROVIDER` | _(auto)_ | `healthchecks`, `uptime-kuma` / `kuma`, or leave empty to auto-detect from the URL |
| `ENTE_DATA_PATH` | `.` | Host directory containing `cli-data/` and `data/` |
| `RUN_USER` | `enteuser` | User that runs exports in both modes |

## Hardening

The included `compose.yaml` runs the container with:

| Setting | Why |
|---------|-----|
| `read_only: true` | Root filesystem is immutable; only the volumes and two tmpfs mounts are writable |
| `tmpfs: /tmp, /etc/crontabs` | Export lock and generated crontab, both cleared on restart |
| `init: true` | Forwards `docker stop` to the scheduler so it shuts down at once instead of being killed after 10s |
| `cap_drop: ALL` + `cap_add` | Keeps only `CHOWN`, `DAC_OVERRIDE`, `FOWNER` (fix volume ownership), `SETUID`, `SETGID` (drop to `enteuser`) and `KILL` (lets the init forward signals to `enteuser`) |
| `no-new-privileges` | Nothing inside can regain privileges through setuid binaries |

The examples below leave these keys out for brevity; copy them from
`compose.yaml` into your own file.

## Docker Compose Examples

The following examples use the same data volumes and differ only in the
scheduler configuration. Use one of them as your `compose.yaml`, or set
`SCHEDULER` / related variables with the included Compose file.

### Loop scheduler

This is the default. It runs an export immediately when the container starts,
then waits six hours between runs. The process drops from root to `enteuser`
(uid/gid 1000) after fixing ownership of `/cli-data` and `/data`.

```yaml
services:
  ente-cli:
    image: wittchy/ente-cli:${IMAGE_TAG:-latest}
    container_name: ente-cli
    restart: unless-stopped
    environment:
      SCHEDULER: loop
      LOOP_INTERVAL: 21600
      TZ: America/Chicago
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ${ENTE_DATA_PATH}/cli-data:/cli-data:rw
      - ${ENTE_DATA_PATH}/data:/data:rw
```

### Cron scheduler

This uses Alpine BusyBox `crond` and runs exports at the scheduled clock times.
The container generates its crontab from `CRON_SCHEDULE`. `crond` itself runs as
root, and every export it starts drops to `enteuser`.

Cron runs one export immediately at container startup, then waits for the next
matching clock time. Between runs, BusyBox `crond` stays quiet by default (no
every-minute scan noise). A schedule such as `0 */6 * * *` therefore runs once
on startup and subsequently at six-hour boundaries (00:00 / 06:00 / 12:00 /
18:00 in the container `TZ`) — silence at other times is expected.

```yaml
services:
  ente-cli:
    image: wittchy/ente-cli:${IMAGE_TAG:-latest}
    container_name: ente-cli
    restart: unless-stopped
    environment:
      SCHEDULER: cron
      CRON_SCHEDULE: "0 */6 * * *"
      TZ: America/Chicago
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ${ENTE_DATA_PATH}/cli-data:/cli-data:rw
      - ${ENTE_DATA_PATH}/data:/data:rw
```

## Scheduling Configuration

For the loop scheduler, set the interval in seconds:

```yaml
environment:
  SCHEDULER: loop
  LOOP_INTERVAL: 21600
```

For the cron scheduler, set a standard five-field cron expression:

```yaml
environment:
  SCHEDULER: cron
  CRON_SCHEDULE: "0 */6 * * *"
  TZ: America/Chicago
```

In cron mode, the container creates `/etc/crontabs/root` from
`CRON_SCHEDULE` when that file does not already exist. To manage the complete
crontab yourself, mount it at that path:

```yaml
environment:
  SCHEDULER: cron
volumes:
  - ${ENTE_CRONTAB_PATH}:/etc/crontabs/root:ro
```

The mounted file must contain the full BusyBox crontab entry, including the
command. For example:

| Schedule | Crontab line |
|----------|-------------|
| Daily at 2 AM | `0 2 * * * /entrypoint.sh --run-export >> /proc/1/fd/1 2>&1` |
| Every 6 hours | `0 */6 * * * /entrypoint.sh --run-export >> /proc/1/fd/1 2>&1` |
| Every 30 minutes | `*/30 * * * * /entrypoint.sh --run-export >> /proc/1/fd/1 2>&1` |

Full format:

```
0 */6 * * * /entrypoint.sh --run-export >> /proc/1/fd/1 2>&1
```

`crond` runs in the foreground in cron mode, so it remains the container's
main process. Generated crontabs bake in `SHELL`, `PATH`, `TZ`, `RUN_USER`,
`HEALTHCHECK_URL` and `HEALTHCHECK_PROVIDER` because BusyBox cron does not
pass the container environment to jobs. Crontabs are regenerated from env on
each start unless the crontab file is mounted read-only. The crontab is never
printed to the log, since it holds the healthcheck URL.

Both scheduler modes write export start/output/completion messages to
standard output (visible in Docker, Portainer, and Arcane live logs), prefixed
with `ente-cli:`. Cron is quiet between scheduled runs; set `CROND_LOG_LEVEL=2`
(or `0` for most verbose) to debug BusyBox `crond` itself. The default is `8`
(BusyBox's quiet default).

At startup, the container also logs the selected scheduler, for example:

```
Selected scheduler: loop (every 21600 seconds)
```

or:

```
Selected scheduler: cron (exports run as enteuser)
Crontab: wrote /etc/crontabs/root (schedule: 0 */6 * * *)
...
Initial export done; crond takes over (CRON_SCHEDULE=0 */6 * * *, CROND_LOG_LEVEL=8).
```

## Timezone

Set `TZ` to any zoneinfo name shipped with Alpine `tzdata` (for example
`America/Chicago`, `Europe/Berlin`, `UTC`). This affects:

- BusyBox cron schedule evaluation (local clock)
- Timestamps in container logs

```yaml
environment:
  TZ: America/Chicago
```

## Healthchecks / monitoring pings

Set `HEALTHCHECK_URL` to a push endpoint. The provider is auto-detected from
the URL (`/api/push/` → Uptime Kuma; otherwise Healthchecks.io-style), or set
explicitly with `HEALTHCHECK_PROVIDER` (`healthchecks`, `uptime-kuma`, or
`kuma`).

### Healthchecks.io

| Event | Request |
|-------|---------|
| Job start | `GET $HEALTHCHECK_URL/start` |
| Job success | `GET $HEALTHCHECK_URL` |
| Job failure | `GET $HEALTHCHECK_URL/fail` |

```yaml
environment:
  HEALTHCHECK_URL: https://hc-ping.com/your-uuid-here
```

### Uptime Kuma (Push monitor)

Create a **Push** monitor in Uptime Kuma and paste its push URL. Example for a
host like `https://up.example.com`:

```yaml
environment:
  HEALTHCHECK_URL: https://up.example.com/api/push/TOKEN
  # Optional — auto-detected when the URL contains /api/push/
  # HEALTHCHECK_PROVIDER: uptime-kuma
```

| Event | Request |
|-------|---------|
| Job start | _(skipped — Kuma has no start heartbeat; sending one would reset the timer early during long exports)_ |
| Job success | `GET $HEALTHCHECK_URL?status=up&msg=ok` |
| Job failure | `GET $HEALTHCHECK_URL?status=down&msg=fail` |

If the push URL already has a query string, parameters are appended with `&`.

**Heartbeat interval:** set the Kuma monitor’s heartbeat slightly longer than
your export interval so a slow job still finishes before the monitor goes down.
Examples: loop every 6h (`LOOP_INTERVAL=21600`) → heartbeat 7–8h; cron every
6h → heartbeat ~7–8h.

Ping failures are logged as warnings and never fail the export job itself.
The warning names only the host, because the push URL is the secret.

## CLI Usage

```bash
# List accounts (-u enteuser keeps files owned by the export user)
docker exec -it -u enteuser ente-cli /usr/local/bin/ente-cli account list

# Run an export manually
docker exec -it -u enteuser ente-cli /usr/local/bin/ente-cli export
```


## Volumes

| Path | Purpose |
|------|---------|
| `/cli-data` | Account credentials & config (persist across restarts) |
| `/data` | Export destination (decrypted files) |
| `/etc/crontabs/root` | Optional cron schedule (mounted read-only) |

## Verifying schedulers

A mock-based smoke test covers both schedulers without an Ente account:

```bash
./scripts/smoke-test.sh
```

It builds the real image, swaps `ente-cli` for a mock, and runs both modes with
the same hardening flags as `compose.yaml`. It checks that exports run as
`enteuser` in both modes and repeat on schedule, that `TZ` reaches cron jobs,
that the healthcheck URL never appears in the log, and that `docker stop`
shuts the container down cleanly. CI runs it on every pull request and before
every push to Docker Hub.

## Building

The image is built automatically by GitHub Actions on every push to `main`
(and daily when a new upstream `cli-v*` tag appears). Images are tagged as:

- `wittchy/ente-cli:latest`
- `wittchy/ente-cli:cli-v0.3.0` (upstream release tag)
- `wittchy/ente-cli:v0.3.0` (version with `cli-` prefix stripped)
- `wittchy/ente-cli:<github-sha>`

A daily cleanup workflow keeps `latest`, all `cli-v*` / `v*` release tags, and
the 6 most recent other tags (git SHAs). For each tag it removes, it also
deletes the multi-arch index and per-arch manifests via the Registry API so
buildx pushes do not leave dangling digests. Digests still used by a kept tag
are never deleted, since a rebuild of unchanged source can produce the same
digest as `latest`. Untagged leftovers from older
tag-only cleanups may still need a one-time pass in the Docker Hub UI (Hub
does not expose untagged-image deletion via JWT alone).

Schedule skip detection uses the Actions cache (last built upstream tag).
When the pin in `UPSTREAM_TAG` is stale after a successful build, CI opens a
PR on `chore/upstream-tag` instead of committing directly to `main`.

To build locally against the recorded upstream release:

```bash
TAG="$(cat UPSTREAM_TAG)"
docker build \
  --build-arg UPSTREAM_REF="$TAG" \
  --build-arg VERSION="${TAG#cli-}" \
  -t "wittchy/ente-cli:${TAG}" .
```

## Security Notes

- Exports are **decrypted on disk** — protect the `/data` and `/cli-data` volumes
- Back up `/cli-data` to avoid re-authenticating
- Exports run as `enteuser` (uid 1000) in both modes; only BusyBox `crond` stays root in cron mode
- Use the hardening keys from `compose.yaml` (see [Hardening](#hardening))
- Treat `HEALTHCHECK_URL` as a secret; anyone with it can mark your job up or down
- If you previously ran exports as root, `/data` files may still be root-owned; fix once with `chown -R 1000:1000 data`
- Do not expose the Docker host or Portainer to the internet
- Prefer binding volumes to host paths with restricted permissions

## License

The `ente-cli` binary is licensed under [AGPL-3.0](https://github.com/ente-io/ente/blob/main/LICENSE).
