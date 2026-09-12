#!/bin/sh

echo "=== Ente CLI Container Starting ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "CLI Version: $(/usr/local/bin/ente-cli version 2>&1)"
echo ""
echo "Crontab loaded:"
cat /etc/crontabs/enteuser 2>&1 | sed 's/^/  /'   
echo ""
echo "Starting crond..."
echo "================================="

cat <<EOF > /etc/crontabs/enteuser
0 */6 * * * /usr/local/bin/ente-cli export
EOF

exec crond -f -l 8
