# ente-cli

[![Build and Push to Docker Hub](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml)
[![Cleanup Docker Hub Tags](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml/badge.svg)](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml)

Minimal Alpine container for the [Ente CLI](https://github.com/ente-io/ente/tree/main/cli) with configurable loop or cron scheduling for automated exports.

Built from the latest upstream [`cli-v*`](https://github.com/ente-io/ente/releases) release tag via GitHub Actions and published to [Docker Hub](https://hub.docker.com/r/wittchy/ente-cli) for `linux/amd64` and `linux/arm64`.

## Features

- Static `ente-cli` binary built from a pinned `cli-v*` release (sparse checkout of `cli/` only)
- Digest-pinned base images and commit-SHA-pinned GitHub Actions
- Loop-based scheduled exports by default (runs as non-root `enteuser`)
- Optional Alpine BusyBox cron scheduling (root; configurable via env or a mounted crontab)
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

# One-time login (match the loop-mode user)
docker exec -it -u enteuser ente-cli /usr/local/bin/ente-cli account add
```


Optional environment overrides for Compose:

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_TAG` | `latest` | Image tag |
| `SCHEDULER` | `loop` | `loop` or `cron` |
| `LOOP_INTERVAL` | `21600` | Seconds between loop exports |
| `CRON_SCHEDULE` | `0 */6 * * *` | Cron expression when `SCHEDULER=cron` |
| `TZ` | `UTC` | Container timezone (affects cron local time + log timestamps) |
| `HEALTHCHECK_URL` | _(empty)_ | Push URL for Healthchecks.io / Uptime Kuma / similar |
| `ENTE_DATA_PATH` | `.` | Host directory containing `cli-data/` and `data/` |
| `RUN_USER` | `enteuser` | User for loop mode after privilege drop |

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
The container generates its crontab from `CRON_SCHEDULE`. Cron mode stays root.

Cron runs one export immediately at container startup, then waits for the next
matching clock time. A schedule such as `0 */6 * * *` therefore runs once on
startup and subsequently at six-hour boundaries (in the container `TZ`).

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
main process. Generated crontabs bake in `SHELL`, `PATH`, `TZ`, and
`HEALTHCHECK_URL` because BusyBox cron does not reliably inherit the
container environment for jobs. Crontabs are regenerated from env on each
start unless the crontab file is mounted read-only.

Both scheduler modes write export start/output/completion messages to
standard output (visible in Docker, Portainer, and Arcane live logs).
Tune BusyBox verbosity with `CROND_LOG_LEVEL` (default `2`; `0` is most
verbose).

At startup, the container also logs the selected scheduler, for example:

```
Selected scheduler: loop (every 21600 seconds)
```

or:

```
Selected scheduler: cron
Starting Alpine BusyBox crond in foreground (logging to stdout)...
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

Set `HEALTHCHECK_URL` to a push endpoint. On each export the container will:

| Event | Request |
|-------|---------|
| Job start | `GET $HEALTHCHECK_URL/start` |
| Job success | `GET $HEALTHCHECK_URL` |
| Job failure | `GET $HEALTHCHECK_URL/fail` |

This matches [Healthchecks.io](https://healthchecks.io) and is compatible with
other monitors that use the same URL shape (for example Uptime Kuma push
monitors).

```yaml
environment:
  HEALTHCHECK_URL: https://hc-ping.com/your-uuid-here
```

Ping failures are logged as warnings and never fail the export job itself.

## CLI Usage

```bash
# List accounts (use -u enteuser in loop mode so files stay owned correctly)
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

It asserts that loop mode drops to `enteuser` and fires repeatedly, and that
cron mode runs an initial export plus a BusyBox `crond`-scheduled export with
baked-in `TZ` / `HEALTHCHECK_URL`.

## Building

The image is built automatically by GitHub Actions on every push to `main`
(and daily when a new upstream `cli-v*` tag appears). Images are tagged as:

- `wittchy/ente-cli:latest`
- `wittchy/ente-cli:cli-v0.3.0` (upstream release tag)
- `wittchy/ente-cli:v0.3.0` (version with `cli-` prefix stripped)
- `wittchy/ente-cli:<github-sha>`

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
- Loop mode drops to `enteuser` (uid 1000). Cron mode stays root for BusyBox `crond`
- If you previously ran as root, `/data` files may still be root-owned; fix once with `chown -R 1000:1000 data`
- Do not expose the Docker host or Portainer to the internet
- Prefer binding volumes to host paths with restricted permissions

## License

The `ente-cli` binary is licensed under [AGPL-3.0](https://github.com/ente-io/ente/blob/main/LICENSE).
