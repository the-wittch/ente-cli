#!/bin/sh

set -eu

SCHEDULER="${SCHEDULER:-loop}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}"
LOOP_INTERVAL="${LOOP_INTERVAL:-21600}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
CRONTAB_DIR="$(dirname "$CRONTAB_FILE")"

run_export() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Running scheduled export job..."
    /usr/local/bin/ente-cli export 2>&1 | sed 's/^/  /'
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Job complete."
}

if [ "${1:-}" = "--run-export" ]; then
    run_export
    exit 0
fi

echo "=== Ente CLI Container Starting ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "CLI Version: $(/usr/local/bin/ente-cli version 2>&1)"
echo ""

if [ ! -f /cli-data/ente-cli.db ]; then
    echo "WARNING: /cli-data/ente-cli.db not found."
    echo "You need to run 'ente-cli account add' to log in first."
    echo "  docker exec -it ente-cli /usr/local/bin/ente-cli account add"
    echo ""
fi

case "$SCHEDULER" in
    loop)
        echo "Selected scheduler: loop (every ${LOOP_INTERVAL} seconds)"
        ;;
    cron)
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
    echo "Starting Alpine BusyBox crond in foreground..."
    exec crond -f -l 2 -c "$CRONTAB_DIR"
fi

echo "Starting loop scheduler..."
while true; do
    run_export
    echo "Next run in ${LOOP_INTERVAL} seconds."
    sleep "$LOOP_INTERVAL"
done
