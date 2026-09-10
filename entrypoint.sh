#!/bin/sh

echo "=== Ente CLI Container Starting ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Version: $(/usr/local/bin/ente-cli version 2>&1)"
echo ""
echo "Crontab loaded:"
crontab -l -u enteuser 2>&1 | sed 's/^/  /'
echo ""
echo "Starting crond..."
echo "================================="

exec crond -f -l 8
