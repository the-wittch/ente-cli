# ente-cli

[![Build and Push to Docker Hub](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/the-wittch/ente-cli/actions/workflows/docker.yml)
[![Cleanup Docker Hub Tags](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml/badge.svg)](https://github.com/the-wittch/ente-cli/actions/workflows/cleanup.yml)

Minimal Alpine container for the [Ente CLI](https://github.com/ente-io/ente/tree/main/cli) with built-in cron support for automated, scheduled exports.

Built from source on every push via GitHub Actions and published to [Docker Hub](https://hub.docker.com/r/wittch/ente-cli).

## Features

- Static `ente-cli` binary built from the latest `ente-io/ente` source
- Cron-based scheduled exports (configurable via mounted crontab)
- Minimal image (~15 MB, Alpine + binary + BusyBox crond)
- No CGO dependencies

## Quick Start

```bash
# Create directories and crontab
mkdir -p cli-data export
echo "0 */6 * * * /usr/local/bin/ente-cli export 2>&1" > crontab

# Start
docker compose up -d

# One-time login
docker exec -it ente-cli /usr/local/bin/ente-cli account add
```

## Docker Compose

```yaml
services:
  ente-cli:
    image: wittchy/ente-cli:${IMAGE_TAG:-latest}
    container_name: ente-cli
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ${ENTE_DATA_PATH}/cli-data:/cli-data:rw
      - ${ENTE_DATA_PATH}/data:/data:rw
      - ${ENTE_CRONTAB_PATH}:/etc/crontabs/enteuser:rw
    networks:
      - proxy

networks:
  proxy:
    external: true
```

## Cron Schedules

Edit your `crontab` file, then `docker compose restart`:

| Schedule | Crontab line |
|----------|-------------|
| Daily at 2 AM | `0 2 * * *` |
| Every 6 hours | `0 */6 * * *` |
| Every 30 minutes | `*/30 * * * *` |

Full format:

```
0 */6 * * * /usr/local/bin/ente-cli export 2>&1
```

## Usage

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
| `/etc/crontabs/enteuser` | Cron schedule (mounted read-only) |

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
