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

echo "Crontab:"
cat /var/spool/cron/crontabs/enteuser 2>/dev/null | sed 's/^/  /' || echo "  (none found)"
echo ""
echo "Starting crond..."
echo "================================="

# Ensure crontab has correct permissions
chmod 600 /var/spool/cron/crontabs/enteuser 2>/dev/null

# Run crond as root (it will drop to enteuser for job execution)
exec crond -f -l 2
