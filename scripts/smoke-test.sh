#!/bin/sh
set -eu

IMAGE="${IMAGE:-ente-cli-smoke}"
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
LOOP_CID=""
CRON_CID=""
trap 'rm -rf "$WORKDIR"; docker rm -f "$LOOP_CID" "$CRON_CID" >/dev/null 2>&1 || true' EXIT

run_hardened() {
    docker run --init --read-only --tmpfs /tmp --tmpfs /etc/crontabs \
        --security-opt no-new-privileges:true --cap-drop ALL \
        --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
        --cap-add KILL --cap-add SETGID --cap-add SETUID "$@"
}

stop_and_collect() {
    started="$(date +%s)"
    docker stop -t 8 "$1" >/dev/null
    took=$(($(date +%s) - started))
    docker logs "$1" >"$2" 2>&1 || true
    docker rm -f "$1" >/dev/null
    if [ "$took" -ge 5 ]; then
        cat "$2"
        echo "ERROR: took ${took}s to stop, SIGTERM is not reaching the scheduler" >&2
        exit 1
    fi
}

echo "Building the runtime image..."
docker build --target runtime -t "$IMAGE-base" "$ROOT" >"$WORKDIR/build.log" 2>&1 || {
    cat "$WORKDIR/build.log" >&2
    exit 1
}

echo ""
echo "=== real ente-cli under the read-only filesystem ==="
mkdir "$WORKDIR/cli-data"
chmod 0777 "$WORKDIR/cli-data"
if ! REAL="$(run_hardened --rm --user 1000:1000 -v "$WORKDIR/cli-data:/cli-data" \
    --entrypoint /usr/local/bin/ente-cli "$IMAGE-base" version 2>&1)"; then
    echo "$REAL"
    echo "ERROR: ente-cli could not start with a read-only root filesystem" >&2
    exit 1
fi
echo "$REAL"
echo "REAL CLI OK"

cat >"$WORKDIR/Dockerfile" <<EOF
FROM $IMAGE-base
RUN printf '%s\n' \
        '#!/bin/sh' \
        'if [ "\${1:-}" = "version" ]; then echo "ente-cli mock 0.0.0"; exit 0; fi' \
        'echo "MOCK_EXPORT user=\$(id -un) uid=\$(id -u) tz=\${TZ:-unset}"' \
        > /usr/local/bin/ente-cli \
    && chmod +x /usr/local/bin/ente-cli
EOF
docker build -t "$IMAGE" "$WORKDIR" >"$WORKDIR/build.log" 2>&1 || {
    cat "$WORKDIR/build.log" >&2
    exit 1
}

echo ""
echo "=== loop (interval 2s) ==="
LOOP_CID="$(run_hardened -d \
    -e SCHEDULER=loop \
    -e LOOP_INTERVAL=2 \
    -e TZ=UTC \
    -e HEALTHCHECK_URL=https://example.invalid/ping/secret-token \
    "$IMAGE")"
sleep 7
LOOP_LOG="$WORKDIR/loop.log"
stop_and_collect "$LOOP_CID" "$LOOP_LOG"
LOOP_CID=""
cat "$LOOP_LOG"

grep -q 'Dropping privileges to enteuser' "$LOOP_LOG"
grep -q 'Selected scheduler: loop' "$LOOP_LOG"
grep -q 'MOCK_EXPORT user=enteuser uid=1000' "$LOOP_LOG"
grep -q 'Received signal, shutting down' "$LOOP_LOG"
if grep -q 'secret-token' "$LOOP_LOG"; then
    echo "ERROR: the healthcheck url leaked into the log" >&2
    exit 1
fi
LOOP_JOBS="$(grep -c 'Job complete\.' "$LOOP_LOG" || true)"
if [ "$LOOP_JOBS" -lt 2 ]; then
    echo "ERROR: expected >=2 loop jobs, got $LOOP_JOBS" >&2
    exit 1
fi
echo "LOOP OK ($LOOP_JOBS jobs)"

echo ""
echo "=== cron (every minute) ==="
CRON_CID="$(run_hardened -d \
    -e SCHEDULER=cron \
    -e 'CRON_SCHEDULE=* * * * *' \
    -e TZ=UTC \
    -e HEALTHCHECK_URL=https://example.invalid/ping/secret-token \
    "$IMAGE")"

CRON_LOG="$WORKDIR/cron.log"
i=0
while [ "$i" -lt 90 ]; do
    docker logs "$CRON_CID" >"$CRON_LOG" 2>&1 || true
    if [ "$(grep -c 'MOCK_EXPORT ' "$CRON_LOG" 2>/dev/null || true)" -ge 2 ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
stop_and_collect "$CRON_CID" "$CRON_LOG"
CRON_CID=""
cat "$CRON_LOG"

grep -q 'Selected scheduler: cron (exports run as enteuser)' "$CRON_LOG"
grep -q 'crond takes over' "$CRON_LOG"
if grep -q 'secret-token' "$CRON_LOG"; then
    echo "ERROR: the healthcheck url leaked into the log" >&2
    exit 1
fi
CRON_JOBS="$(grep -c 'MOCK_EXPORT user=enteuser uid=1000 tz=UTC' "$CRON_LOG" || true)"
if [ "$CRON_JOBS" -lt 2 ]; then
    echo "ERROR: expected the startup export and a scheduled one as enteuser, got $CRON_JOBS" >&2
    exit 1
fi
echo "CRON OK ($CRON_JOBS jobs)"

echo ""
echo "All smoke tests passed."
