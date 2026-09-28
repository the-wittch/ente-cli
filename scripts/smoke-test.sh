#!/bin/sh
# Smoke-test loop and cron schedulers with a mock ente-cli (no Ente account needed).
set -eu

IMAGE="${IMAGE:-ente-cli-smoke}"
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; docker rm -f "$LOOP_CID" "$CRON_CID" >/dev/null 2>&1 || true' EXIT

echo "Building smoke image..."
cat > "$WORKDIR/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata su-exec \
    && addgroup -g 1000 enteuser \
    && adduser -D -u 1000 -G enteuser enteuser \
    && mkdir -p /cli-data /data \
    && chown enteuser:enteuser /cli-data /data
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && printf '%s\n' \
        '#!/bin/sh' \
        'if [ "${1:-}" = "version" ]; then echo "ente-cli mock 0.0.0"; exit 0; fi' \
        'echo "MOCK_EXPORT user=$(id -un) uid=$(id -u) tz=${TZ:-unset} hc=${HEALTHCHECK_URL:-unset}"' \
        'exit 0' \
        > /usr/local/bin/ente-cli \
    && chmod +x /usr/local/bin/ente-cli
ENV TZ=UTC
ENTRYPOINT ["/entrypoint.sh"]
EOF

cp "$ROOT/entrypoint.sh" "$WORKDIR/entrypoint.sh"
docker build -t "$IMAGE" "$WORKDIR" >/tmp/ente-smoke-build.log

echo ""
echo "=== LOOP smoke test (interval=2s, ~7s runtime) ==="
LOOP_CID="$(docker run -d \
    -e SCHEDULER=loop \
    -e LOOP_INTERVAL=2 \
    -e TZ=UTC \
    -e HEALTHCHECK_URL=https://example.invalid/ping \
    "$IMAGE")"
sleep 7
LOOP_LOG="$WORKDIR/loop.log"
docker logs "$LOOP_CID" >"$LOOP_LOG" 2>&1 || true
docker rm -f "$LOOP_CID" >/dev/null
LOOP_CID=""

echo "--- loop log ---"
cat "$LOOP_LOG"
echo "----------------"

grep -q 'Dropping privileges to enteuser' "$LOOP_LOG"
grep -q 'Selected scheduler: loop' "$LOOP_LOG"
grep -q 'MOCK_EXPORT user=enteuser uid=1000' "$LOOP_LOG"
LOOP_JOBS="$(grep -c 'Job complete\.' "$LOOP_LOG" || true)"
if [ "$LOOP_JOBS" -lt 2 ]; then
    echo "ERROR: expected >=2 loop jobs, got $LOOP_JOBS" >&2
    exit 1
fi
echo "LOOP OK ($LOOP_JOBS jobs)"

echo ""
echo "=== CRON smoke test (* * * * *, wait for scheduled fire) ==="
# Quote the schedule carefully so the shell never glob-expands '*'.
CRON_CID="$(docker run -d \
    -e SCHEDULER=cron \
    -e 'CRON_SCHEDULE=* * * * *' \
    -e TZ=UTC \
    -e HEALTHCHECK_URL=https://example.invalid/ping \
    "$IMAGE")"

CRON_LOG="$WORKDIR/cron.log"
i=0
while [ "$i" -lt 90 ]; do
    docker logs "$CRON_CID" >"$CRON_LOG" 2>&1 || true
    JOBS="$(grep -c 'MOCK_EXPORT ' "$CRON_LOG" 2>/dev/null || true)"
    if [ "${JOBS:-0}" -ge 2 ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

docker logs "$CRON_CID" >"$CRON_LOG" 2>&1 || true
docker rm -f "$CRON_CID" >/dev/null
CRON_CID=""

echo "--- cron log ---"
cat "$CRON_LOG"
echo "----------------"

grep -q 'Selected scheduler: cron' "$CRON_LOG"
grep -q 'HEALTHCHECK_URL=https://example.invalid/ping' "$CRON_LOG"
grep -q 'Starting Alpine BusyBox crond' "$CRON_LOG"
grep -q 'crond (busybox' "$CRON_LOG"
CRON_JOBS="$(grep -c 'MOCK_EXPORT ' "$CRON_LOG" || true)"
if [ "$CRON_JOBS" -lt 2 ]; then
    echo "ERROR: expected initial + scheduled cron export (>=2), got $CRON_JOBS" >&2
    exit 1
fi
grep -q 'MOCK_EXPORT user=root uid=0' "$CRON_LOG"
if ! grep -q 'MOCK_EXPORT user=root uid=0 tz=UTC hc=https://example.invalid/ping' "$CRON_LOG"; then
    echo "ERROR: cron job missing baked environment (TZ/HEALTHCHECK_URL)" >&2
    exit 1
fi
echo "CRON OK ($CRON_JOBS jobs)"

echo ""
echo "All smoke tests passed."
