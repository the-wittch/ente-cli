#!/bin/sh

set -eu

SCHEDULER="${SCHEDULER:-loop}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}"
LOOP_INTERVAL="${LOOP_INTERVAL:-21600}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
CRONTAB_DIR="$(dirname "$CRONTAB_FILE")"
RUN_USER="${RUN_USER:-enteuser}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
HEALTHCHECK_PROVIDER="${HEALTHCHECK_PROVIDER:-}"
LOCK_DIR="${LOCK_DIR:-/tmp/ente-export.lock}"
CROND_LOG_LEVEL="${CROND_LOG_LEVEL:-8}"
TZ="${TZ:-UTC}"
export TZ

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    echo "ente-cli: Received signal, shutting down."
    exit 0
}
trap cleanup TERM INT

log() {
    echo "ente-cli: [$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"
}

append_query() {
    case "$1" in
        *\?*) printf '%s&%s' "$1" "$2" ;;
        *) printf '%s?%s' "$1" "$2" ;;
    esac
}

resolve_healthcheck_provider() {
    provider="$(printf '%s' "$HEALTHCHECK_PROVIDER" | tr '[:upper:]' '[:lower:]')"
    case "$provider" in
        uptime-kuma|kuma) echo kuma; return 0 ;;
        healthchecks|hc) echo healthchecks; return 0 ;;
    esac
    case "$HEALTHCHECK_URL" in
        */api/push/*) echo kuma ;;
        *) echo healthchecks ;;
    esac
}

ping_healthcheck() {
    [ -n "$HEALTHCHECK_URL" ] || return 0

    base="${HEALTHCHECK_URL%/}"
    if [ "$(resolve_healthcheck_provider)" = "kuma" ]; then
        case "$1" in
            # kuma has no start heartbeat; one would reset its timer mid-export
            start) return 0 ;;
            success) target="$(append_query "$base" "status=up&msg=ok")" ;;
            fail) target="$(append_query "$base" "status=down&msg=fail")" ;;
            *) return 0 ;;
        esac
    else
        case "$1" in
            success) target="$base" ;;
            fail) target="${base}/fail" ;;
            start) target="${base}/start" ;;
            *) return 0 ;;
        esac
    fi

    set +e
    err="$(curl -fsS -o /dev/null --connect-timeout 10 --max-time 15 "$target" 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        # the url is the secret, so name the host only
        host="$(printf '%s' "$target" | sed -E 's#^([a-zA-Z]+://[^/?]+).*#\1#')"
        echo "WARNING: healthcheck ping failed (${1}, exit ${rc}) to ${host}: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)" >&2
    fi
}

ente() {
    if [ "$(id -u)" -eq 0 ]; then
        su-exec "$RUN_USER" /usr/local/bin/ente-cli "$@"
    else
        /usr/local/bin/ente-cli "$@"
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
    (
        # shellcheck disable=SC3040 # busybox ash has pipefail
        set -o pipefail
        ente export 2>&1 | sed 's/^/  /'
    )
    status=$?
    set -e

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
    # busybox crond doesn't pass the container env to jobs
    {
        echo "SHELL=/bin/sh"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "TZ=${TZ}"
        echo "RUN_USER=${RUN_USER}"
        if [ -n "$HEALTHCHECK_URL" ]; then
            echo "HEALTHCHECK_URL=${HEALTHCHECK_URL}"
        fi
        if [ -n "$HEALTHCHECK_PROVIDER" ]; then
            echo "HEALTHCHECK_PROVIDER=${HEALTHCHECK_PROVIDER}"
        fi
        printf '%s %s\n' "$CRON_SCHEDULE" '/entrypoint.sh --run-export >> /proc/1/fd/1 2>&1'
    } > "$CRONTAB_FILE"
    chmod 600 "$CRONTAB_FILE"
}

if [ "${1:-}" = "--run-export" ]; then
    run_export
    exit $?
fi

if [ "$(id -u)" -eq 0 ]; then
    if ! id "$RUN_USER" >/dev/null 2>&1; then
        echo "ERROR: RUN_USER '$RUN_USER' does not exist." >&2
        exit 1
    fi
    # /tmp outlives a restart; an export cut off by a stop leaves its lock behind
    rmdir "$LOCK_DIR" 2>/dev/null || true
    chown "$RUN_USER:$RUN_USER" /cli-data /data 2>/dev/null || true
    chown -R "$RUN_USER:$RUN_USER" /cli-data 2>/dev/null || true

    if [ "$SCHEDULER" = "loop" ]; then
        echo "Dropping privileges to ${RUN_USER} for loop scheduler..."
        exec su-exec "$RUN_USER" /entrypoint.sh "$@"
    fi
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
    echo "WARNING: /cli-data/ente-cli.db not found. Log in first:"
    echo "  docker exec -it -u ${RUN_USER} ente-cli /usr/local/bin/ente-cli account add"
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
        echo "Selected scheduler: cron (exports run as ${RUN_USER})"
        mkdir -p "$CRONTAB_DIR"

        if [ -f "$CRONTAB_FILE" ] && [ ! -w "$CRONTAB_FILE" ]; then
            echo "Crontab: using mounted read-only file $CRONTAB_FILE"
        else
            write_crontab
            echo "Crontab: wrote $CRONTAB_FILE (schedule: $CRON_SCHEDULE)"
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
    run_export || true
    echo "Initial export done; crond takes over (CRON_SCHEDULE=${CRON_SCHEDULE}, CROND_LOG_LEVEL=${CROND_LOG_LEVEL})."
    exec crond -f -l "$CROND_LOG_LEVEL" -L /proc/1/fd/1 -c "$CRONTAB_DIR"
fi

while true; do
    run_export || true
    echo "Next run in ${LOOP_INTERVAL} seconds."
    sleep "$LOOP_INTERVAL" &
    wait $! || true
done
