#!/usr/bin/env bash
# Cluster members and where MySQL Router is sending traffic.
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../../scripts/lib/common.sh"

"${COMPOSE[@]}" exec -T tools mysqlsh --no-defaults --js --file /cluster/status.js 2>/dev/null
for port in 6446 6447; do
    host="$("${COMPOSE[@]}" exec -T tools sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -h router -P $port -uroot -N --connect-timeout=2 -e 'SELECT @@hostname'" 2>/dev/null || echo unavailable)"
    echo "router :$port -> $host"
done
