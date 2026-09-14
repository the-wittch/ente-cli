#!/bin/sh

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

echo "Cron schedule: every 6 hours"
echo ""
echo "Starting scheduler..."
echo "================================="

# Run cron job every 6 hours
while true; do
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Running scheduled export job..."
    /usr/local/bin/ente-cli export 2>&1 | sed 's/^/  /'
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Job complete. Next run in 6 hours."
    sleep 21600  # 6 hours in seconds
done
