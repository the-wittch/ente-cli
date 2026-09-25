# ente-cli

[![Build and Push to Docker Hub](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml)
[![Cleanup Docker Hub Tags](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml/badge.svg)](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml)

Minimal Alpine container for the [Ente CLI](https://github.com/ente-io/ente/tree/main/cli) with configurable loop or cron scheduling for automated exports.

Built from source on every push via GitHub Actions and published to [Docker Hub](https://hub.docker.com/r/wittch/ente-cli).

## Features

- Static `ente-cli` binary built from the latest `ente-io/ente` source
- Loop-based scheduled exports by default
- Optional Alpine BusyBox cron scheduling (configurable via environment variables or a mounted crontab)
- Minimal image (~15 MB, Alpine + binary + BusyBox crond)
- No CGO dependencies

## Quick Start

```bash
# Create directories
mkdir -p cli-data export

# Start
docker compose up -d

# One-time login
docker exec -it ente-cli /usr/local/bin/ente-cli account add
```

## Docker Compose Examples

The following examples use the same data volumes and differ only in the
scheduler configuration. Use one of them as your `compose.yaml`.

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
    networks:
      - proxy

networks:
  proxy:
    external: true
```

### Cron scheduler

This uses Alpine BusyBox `crond` and runs exports at the scheduled clock times.
The container generates its crontab from `CRON_SCHEDULE`.

Cron does not run an export immediately at container startup. It waits for the
next matching clock time, so a schedule such as `0 */6 * * *` may wait several
hours before its first run. Run an export manually after login if needed.

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
    networks:
      - proxy

networks:
  proxy:
    external: true
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
main process. Both scheduler modes write the export start message, command
output, and completion message to standard output, so they are visible in
Docker, Portainer, and Arcane logs. BusyBox cron uses the container's timezone;
configure the timezone if local-time scheduling is required.

At startup, the container also logs the selected scheduler, for example:

```
Selected scheduler: loop (every 21600 seconds)
```

or:

```
Selected scheduler: cron
Starting Alpine BusyBox crond in foreground...
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

The image is built automatically by GitHub Actions on every push to `main` and pushed to `wittchy/ente-cli:latest` on Docker Hub.

To build locally:

```bash
docker build -t wittchy/ente-cli:latest .
```

## Security Notes

- Exports are **decrypted on disk** — protect the `/data` and `/cli-data` volumes
- Back up `/cli-data` to avoid re-authenticating
- Do not expose the Docker host or Portainer to the internet

## License

The `ente-cli` binary is licensed under [AGPL-3.0](https://github.com/ente-io/ente/blob/main/LICENSE).   
