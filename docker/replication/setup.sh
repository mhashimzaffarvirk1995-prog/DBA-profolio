#!/usr/bin/env bash
# Build classic GTID replication: primary -> replica1, replica2.
#
#   1. schema + the small dataset on the primary
#   2. replication and clone accounts on the primary
#   3. each replica cloned from the primary (physical copy via the clone
#      plugin), then pointed at it with GTID auto-positioning
#   4. replicas made read-only, then verified
#
# Run via `make repl-setup` after `make repl-up`. Safe to re-run: finished
# steps are skipped.
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../../scripts/lib/common.sh"

REPL_PASSWORD="$(env_value REPL_PASSWORD)"
[[ -n "$REPL_PASSWORD" ]] || { echo "REPL_PASSWORD missing from .env: run 'make .env'" >&2; exit 1; }
DATA_DIR="${DATA_DIR:-$ROOT/data/generated-small}"
REPLICAS=(replica1 replica2)

for c in payflow-primary payflow-replica1 payflow-replica2; do wait_healthy "$c"; done

step "1. Schema and data on the primary"
if [[ "$(q primary "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'payflow'")" == 1 ]]; then
    echo "payflow already exists on the primary, skipping load"
else
    [[ -f "$DATA_DIR/customers.csv" ]] || {
        echo "No data in $DATA_DIR. Run: python3 scripts/generate_data.py --transactions 200000 --customers 20000 --out data/generated-small" >&2
        exit 1; }
    sql primary -e "CREATE DATABASE payflow CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
    sql primary payflow < "$ROOT/schema/01_tables.sql"
    sql primary payflow < "$ROOT/schema/02_procedures.sql"
    DATA_DIR="$DATA_DIR" COMPOSE_FILE="$COMPOSE_FILE" SERVICE=primary "$ROOT/scripts/load_data.sh" payflow | tail -3
    sql primary payflow < "$ROOT/schema/03_triggers.sql"
fi

step "2. Replication and clone accounts on the primary"
# REQUIRE SSL: replication traffic carries customer data, so it is encrypted.
sql primary <<SQL
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '$REPL_PASSWORD' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
CREATE USER IF NOT EXISTS 'clone_donor'@'%' IDENTIFIED BY '$REPL_PASSWORD' REQUIRE SSL;
GRANT BACKUP_ADMIN ON *.* TO 'clone_donor'@'%';
SQL
[[ "$(q primary "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name = 'clone'")" == 1 ]] \
    || sql primary -e "INSTALL PLUGIN clone SONAME 'mysql_clone.so'"
echo "repl and clone_donor ready"

for r in "${REPLICAS[@]}"; do
    step "3. $r: clone from primary and start replication"
    if [[ "$(q "$r" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration")" != 0 ]]; then
        echo "$r is already a replica, skipping"
        continue
    fi
    [[ "$(q "$r" "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name = 'clone'")" == 1 ]] \
        || sql "$r" -e "INSTALL PLUGIN clone SONAME 'mysql_clone.so'"
    sql "$r" -e "SET GLOBAL clone_valid_donor_list = 'primary:3306'"

    # Replaces the replica's data directory with a copy of the primary's, then
    # mysqld restarts itself. Nothing supervises mysqld inside the container,
    # so the client sees error 3707 and Docker's restart policy brings it back.
    t0=$(date +%s)
    out="$(sql "$r" -e "CLONE INSTANCE FROM 'clone_donor'@'primary':3306 IDENTIFIED BY '$REPL_PASSWORD' REQUIRE SSL" 2>&1 || true)"
    if [[ -n "$out" && "$out" != *3707* ]]; then
        echo "$out" >&2; exit 1
    fi
    sleep 5
    wait_healthy "payflow-$r"
    echo "cloned in $(( $(date +%s) - t0 ))s ($(q "$r" "SELECT FORMAT(SUM(data_length + index_length) / 1048576, 0) FROM information_schema.tables WHERE table_schema = 'payflow'") MB)"

    # The clone carries the primary's gtid_executed, so auto-positioning
    # starts exactly where the copy ends.
    sql "$r" <<SQL
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST = 'primary', SOURCE_PORT = 3306,
    SOURCE_USER = 'repl', SOURCE_PASSWORD = '$REPL_PASSWORD',
    SOURCE_AUTO_POSITION = 1, SOURCE_SSL = 1,
    SOURCE_CONNECT_RETRY = 5, SOURCE_RETRY_COUNT = 1000;
START REPLICA;
SET PERSIST read_only = ON;
SET PERSIST super_read_only = ON;
SQL
done

step "4. Verify"
"$(dirname "$0")/status.sh"
