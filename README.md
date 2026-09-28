# ente-cli

[![Build and Push to Docker Hub](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml)
[![Cleanup Docker Hub Tags](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml/badge.svg)](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml)

Minimal Alpine container for the [Ente CLI](https://github.com/ente-io/ente/tree/main/cli) with configurable loop or cron scheduling for automated exports.

Built from a pinned `ente-io/ente` commit via GitHub Actions and published to [Docker Hub](https://hub.docker.com/r/wittchy/ente-cli) for `linux/amd64` and `linux/arm64`.

## Features

- Static `ente-cli` binary built from a pinned `ente-io/ente` commit (sparse checkout of `cli/` only)
- Loop-based scheduled exports by default
- Optional Alpine BusyBox cron scheduling (configurable via environment variables or a mounted crontab)
- Minimal image (Alpine + binary + BusyBox crond)
- No CGO dependencies

## Quick Start

```bash
# Create directories
mkdir -p cli-data data

# Start (uses compose.yaml in this repo)
docker compose up -d

# One-time login
docker exec -it ente-cli /usr/local/bin/ente-cli account add
```

Optional environment overrides for Compose:

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_TAG` | `latest` | Image tag |
| `SCHEDULER` | `loop` | `loop` or `cron` |
| `LOOP_INTERVAL` | `21600` | Seconds between loop exports |
| `CRON_SCHEDULE` | `0 */6 * * *` | Cron expression when `SCHEDULER=cron` |
| `ENTE_DATA_PATH` | `.` | Host directory containing `cli-data/` and `data/` |

## Docker Compose Examples

The following examples use the same data volumes and differ only in the
scheduler configuration. Use one of them as your `compose.yaml`, or set
`SCHEDULER` / related variables with the included Compose file.

### Loop scheduler

This is the default. It runs an export immediately when the container starts,
then waits six hours between runs.

```yaml
services:
  ente-cli:
    image: wittchy/ente-cli:${IMAGE_TAG:-latest}
    container_name: ente-cli
    restart: unless-stopped
    environment:
      SCHEDULER: loop
      LOOP_INTERVAL: 21600
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
The container generates its crontab from `CRON_SCHEDULE`.

Cron runs one export immediately at container startup, then waits for the next
matching clock time. A schedule such as `0 */6 * * *` therefore runs once on
startup and subsequently at six-hour boundaries.

```yaml
services:
  ente-cli:
    image: wittchy/ente-cli:${IMAGE_TAG:-latest}
    container_name: ente-cli
    restart: unless-stopped
    environment:
      SCHEDULER: cron
      CRON_SCHEDULE: "0 */6 * * *"
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
main process. BusyBox scheduler diagnostics run at the most verbose log level,
and both scheduler modes' export start message, command output, and completion
message are written to standard output, so they are visible in Docker,
Portainer, and Arcane live logs. BusyBox cron uses the container's timezone;
configure the timezone if local-time scheduling is required.

At startup, the container also logs the selected scheduler, for example:

```
Selected scheduler: loop (every 21600 seconds)
```

or:

```
Selected scheduler: cron
Starting Alpine BusyBox crond in foreground (logging to stdout)...
```

## CLI Usage

```bash
# List accounts
docker exec -it ente-cli /usr/local/bin/ente-cli account list

# Run an export manually
docker exec -it ente-cli /usr/local/bin/ente-cli export
```

## Volumes

| Path | Purpose |
|------|---------|
| `/cli-data` | Account credentials & config (persist across restarts) |
| `/data` | Export destination (decrypted files) |
| `/etc/crontabs/root` | Optional cron schedule (mounted read-only) |

## Building

The image is built automatically by GitHub Actions on every push to `main`
(and daily when upstream `ente-io/ente` changes). Images are tagged as:

- `wittchy/ente-cli:latest`
- `wittchy/ente-cli:<github-sha>`
- `wittchy/ente-cli:upstream-<12-char-upstream-sha>`

To build locally against the recorded upstream commit:

```bash
docker build \
  --build-arg UPSTREAM_SHA="$(cat UPSTREAM_SHA)" \
  --build-arg VERSION="$(cut -c1-12 UPSTREAM_SHA)" \
  -t wittchy/ente-cli:latest .
```

## Security Notes

- Exports are **decrypted on disk** — protect the `/data` and `/cli-data` volumes
- Back up `/cli-data` to avoid re-authenticating
- The container runs as root so BusyBox `crond` can manage system crontabs; do not expose the Docker host or Portainer to the internet
- Prefer binding volumes to host paths with restricted permissions

## License

The `ente-cli` binary is licensed under [AGPL-3.0](https://github.com/ente-io/ente/blob/main/LICENSE).
