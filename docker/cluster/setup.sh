#!/usr/bin/env bash
# Build the InnoDB Cluster: load data into node1, then let MySQL Shell's
# AdminAPI configure all nodes, create the cluster and clone node2/node3,
# and wait for MySQL Router to bootstrap. Run via `make cluster-setup`.
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../../scripts/lib/common.sh"
DATA_DIR="${DATA_DIR:-$ROOT/data/generated-small}"

for c in payflow-node1 payflow-node2 payflow-node3; do wait_healthy "$c"; done

step "1. Schema and data on node1"
if [[ "$(q node1 "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'payflow'")" == 1 ]]; then
    echo "payflow already exists on node1, skipping load"
else
    [[ -f "$DATA_DIR/customers.csv" ]] || {
        echo "No data in $DATA_DIR. Run: python3 scripts/generate_data.py --transactions 200000 --customers 20000 --out data/generated-small" >&2
        exit 1; }
    sql node1 -e "CREATE DATABASE payflow CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
    sql node1 payflow < "$ROOT/schema/01_tables.sql"
    sql node1 payflow < "$ROOT/schema/02_procedures.sql"
    DATA_DIR="$DATA_DIR" COMPOSE_FILE="$COMPOSE_FILE" SERVICE=node1 "$ROOT/scripts/load_data.sh" payflow | tail -3
    sql node1 payflow < "$ROOT/schema/03_triggers.sql"
fi

step "2. Create the cluster (MySQL Shell AdminAPI)"
"${COMPOSE[@]}" exec -T tools mysqlsh --no-defaults --js --file /cluster/setup-cluster.js

step "3. Wait for MySQL Router"
for i in $(seq 1 60); do
    if host="$("${COMPOSE[@]}" exec -T tools sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h router -P 6446 -uroot -N -e "SELECT @@hostname"' 2>/dev/null)"; then
        echo "router is up; read/write port 6446 -> $host"
        break
    fi
    (( i == 60 )) && { echo "router did not come up; see: docker logs payflow-router" >&2; exit 1; }
    sleep 2
done

step "4. Status"
"$(dirname "$0")/status.sh"
