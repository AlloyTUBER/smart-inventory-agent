#!/usr/bin/env bash
set -euo pipefail

# Change PostgreSQL port from 5432 to 3010
# Run once with: sudo bash scripts/setup-db-port.sh

PG_CONF="/etc/postgresql/18/main/postgresql.conf"
NEW_PORT=3010

echo "=== Changing PostgreSQL port to $NEW_PORT ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (use sudo)."
    exit 1
fi

# Backup the original config
cp "$PG_CONF" "${PG_CONF}.bak.$(date +%s)"

# Change the port
sed -i "s/^port = [0-9]*/port = $NEW_PORT/" "$PG_CONF"
echo "  ✓ Updated $PG_CONF"

# Restart PostgreSQL
systemctl restart postgresql
echo "  ✓ PostgreSQL restarted on port $NEW_PORT"

# Verify
su - postgres -c "psql -p $NEW_PORT -c 'SELECT 1;'" > /dev/null 2>&1 \
  && echo "  ✓ PostgreSQL is accepting connections on port $NEW_PORT" \
  || echo "  ✗ Connection test failed — check: journalctl -u postgresql"

echo ""
echo "Backend .env is already configured for port $NEW_PORT"
