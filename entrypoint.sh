#!/bin/sh

set -eu

SCHEDULER="${SCHEDULER:-loop}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}"
LOOP_INTERVAL="${LOOP_INTERVAL:-21600}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
CRONTAB_DIR="$(dirname "$CRONTAB_FILE")"
RUN_USER="${RUN_USER:-enteuser}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
LOCK_DIR="${LOCK_DIR:-/tmp/ente-export.lock}"
CROND_LOG_LEVEL="${CROND_LOG_LEVEL:-2}"
TZ="${TZ:-UTC}"
export TZ

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    echo "Received signal, shutting down."
    exit 0
}
trap cleanup TERM INT

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
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "Previous export still running; skipping this run."
        return 0
    fi

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

    rmdir "$LOCK_DIR" 2>/dev/null || true
    return "$status"
}

write_crontab() {
    # BusyBox crond does not reliably pass the container env to jobs, so bake
    # the needed variables into the crontab itself.
    {
        echo "SHELL=/bin/sh"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "TZ=${TZ}"
        if [ -n "$HEALTHCHECK_URL" ]; then
            echo "HEALTHCHECK_URL=${HEALTHCHECK_URL}"
        fi
        printf '%s %s\n' "$CRON_SCHEDULE" '/entrypoint.sh --run-export >> /proc/1/fd/1 2>&1'
    } > "$CRONTAB_FILE"
    chmod 600 "$CRONTAB_FILE"
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
        mkdir -p "$CRONTAB_DIR"

        if [ -f "$CRONTAB_FILE" ] && [ ! -w "$CRONTAB_FILE" ]; then
            echo "Crontab: using mounted read-only file $CRONTAB_FILE"
        else
            write_crontab
            echo "Crontab: wrote $CRONTAB_FILE from environment"
            echo "Schedule: $CRON_SCHEDULE"
        fi
        echo "----- crontab -----"
        cat "$CRONTAB_FILE"
        echo "-------------------"
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
    exec crond -f -l "$CROND_LOG_LEVEL" -L /proc/1/fd/1 -c "$CRONTAB_DIR"
fi

echo "Starting loop scheduler..."
while true; do
    run_export || true
    echo "Next run in ${LOOP_INTERVAL} seconds."
    sleep "$LOOP_INTERVAL" &
    wait $! || true
done
