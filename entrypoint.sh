#!/bin/sh

set -eu

SCHEDULER="${SCHEDULER:-loop}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}"
LOOP_INTERVAL="${LOOP_INTERVAL:-21600}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
CRONTAB_DIR="$(dirname "$CRONTAB_FILE")"
RUN_USER="${RUN_USER:-enteuser}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
TZ="${TZ:-UTC}"
export TZ

trap 'echo "Received signal, shutting down."; exit 0' TERM INT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"
}

ping_healthcheck() {
    # $1 = success | fail | start
    # Compatible with Healthchecks.io, Uptime Kuma push monitors, etc.
    [ -n "$HEALTHCHECK_URL" ] || return 0

    base="${HEALTHCHECK_URL%/}"
    case "$1" in
        success) target="$base" ;;
        fail) target="${base}/fail" ;;
        start) target="${base}/start" ;;
        *) return 0 ;;
    esac

    if ! wget -q -O /dev/null -T 10 "$target" 2>/dev/null; then
        echo "WARNING: healthcheck ping failed (${1}): $target" >&2
    fi
}

run_export() {
    log "Running scheduled export job..."
    ping_healthcheck start

    set +e
    output="$(/usr/local/bin/ente-cli export 2>&1)"
    status=$?
    set -e

    if [ -n "$output" ]; then
        printf '%s\n' "$output" | sed 's/^/  /'
    fi

    if [ "$status" -eq 0 ]; then
        log "Job complete."
        ping_healthcheck success
    else
        log "Job failed with exit code ${status}." >&2
        ping_healthcheck fail
    fi
    return "$status"
}

if [ "${1:-}" = "--run-export" ]; then
    run_export
    exit $?
fi

# Loop mode runs as non-root. Cron stays root for BusyBox crond/crontabs.
if [ "$SCHEDULER" = "loop" ] && [ "$(id -u)" -eq 0 ]; then
    if ! id "$RUN_USER" >/dev/null 2>&1; then
        echo "ERROR: RUN_USER '$RUN_USER' does not exist." >&2
        exit 1
    fi

    # Directory ownership only for /data (large trees). Fix /cli-data fully.
    chown "$RUN_USER:$RUN_USER" /cli-data /data 2>/dev/null || true
    chown -R "$RUN_USER:$RUN_USER" /cli-data 2>/dev/null || true

    echo "Dropping privileges to ${RUN_USER} for loop scheduler..."
    exec su-exec "$RUN_USER" /entrypoint.sh "$@"
fi

echo "=== Ente CLI Container Starting ==="
log "Time (TZ=${TZ})"
echo "CLI Version: $(/usr/local/bin/ente-cli version 2>&1)"
echo "User: $(id -un) ($(id -u))"
if [ -n "$HEALTHCHECK_URL" ]; then
    echo "Healthcheck: enabled"
fi
echo ""

if [ ! -f /cli-data/ente-cli.db ]; then
    echo "WARNING: /cli-data/ente-cli.db not found."
    echo "You need to run 'ente-cli account add' to log in first."
    echo "  docker exec -it -u $(id -un) ente-cli /usr/local/bin/ente-cli account add"
    echo ""
fi

case "$SCHEDULER" in
    loop)
        if ! [ "$LOOP_INTERVAL" -gt 0 ] 2>/dev/null; then
            echo "ERROR: LOOP_INTERVAL must be a positive integer (got '$LOOP_INTERVAL')." >&2
            exit 1
        fi
        echo "Selected scheduler: loop (every ${LOOP_INTERVAL} seconds)"
        ;;
    cron)
        if [ "$(id -u)" -ne 0 ]; then
            echo "ERROR: SCHEDULER=cron requires running the container as root." >&2
            exit 1
        fi
        echo "Selected scheduler: cron"
        if [ -f "$CRONTAB_FILE" ]; then
            echo "Crontab: $CRONTAB_FILE"
        else
            mkdir -p "$CRONTAB_DIR"
            printf '%s %s\n' "$CRON_SCHEDULE" '/entrypoint.sh --run-export >> /proc/1/fd/1 2>&1' > "$CRONTAB_FILE"
            echo "Crontab: generated $CRONTAB_FILE"
            echo "Schedule: $CRON_SCHEDULE"
        fi
        ;;
    *)
        echo "ERROR: SCHEDULER must be 'loop' or 'cron' (got '$SCHEDULER')." >&2
        exit 1
        ;;
esac

echo ""
echo "Starting scheduler..."
echo "================================="

if [ "$SCHEDULER" = "cron" ]; then
    echo "Running initial export before waiting for the next cron time..."
    run_export || true
    echo "Initial export finished; continuing to crond."
    echo "Starting Alpine BusyBox crond in foreground (logging to stdout)..."
    exec crond -f -l 0 -L /proc/1/fd/1 -c "$CRONTAB_DIR"
fi

echo "Starting loop scheduler..."
while true; do
    run_export || true
    echo "Next run in ${LOOP_INTERVAL} seconds."
    sleep "$LOOP_INTERVAL" &
    wait $! || true
done
