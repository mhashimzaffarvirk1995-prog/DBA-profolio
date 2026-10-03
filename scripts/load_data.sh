#!/usr/bin/env bash
# Bulk-load generated CSVs into a MySQL container.
#
#   scripts/load_data.sh [database]        default: payflow
#
# Environment (defaults load data/generated into the Phase 1 standalone server):
#   DATA_DIR      directory of CSVs, must live under data/   (data/generated)
#   COMPOSE_FILE  compose file of the target server           (docker/standalone/docker-compose.yml)
#   SERVICE       compose service to load into                (mysql)
#
# Runs the mysql client inside the Docker container. To load a server running
# outside Docker instead, set MYSQL_CLIENT to a client command, e.g.
#   MYSQL_CLIENT="mysql -uroot -S /tmp/mysql.sock" scripts/load_data.sh
#
# The schema must exist (make schema) and triggers must NOT be applied yet.
# For speed this script, for the duration of the load only:
#   * disables the InnoDB redo log (ALTER INSTANCE DISABLE INNODB REDO_LOG).
#     A crash while it is off can leave the instance unrecoverable, which is
#     acceptable for an initial load into an empty server and never otherwise.
#   * turns off FK and unique checks (the generator guarantees both)
#   * skips the binary log: replicas in Phase 2 are seeded from a clone or
#     backup, not by replaying 35M row events
#   * enables local_infile, so the mysql client can stream the CSVs
#     (LOAD DATA LOCAL INFILE); it is switched back off afterwards
# With LOCAL, MySQL downgrades bad rows (CHECK violations, duplicates) to
# warnings and skips them, so the load stops if any file produces a warning.
set -euo pipefail

DB="${1:-payflow}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(cd "${DATA_DIR:-$ROOT/data/generated}" && pwd)"
SERVICE="${SERVICE:-mysql}"
COMPOSE=(docker compose --env-file "$ROOT/.env" -f "${COMPOSE_FILE:-$ROOT/docker/standalone/docker-compose.yml}")

sql() {
    if [[ -n "${MYSQL_CLIENT:-}" ]]; then
        $MYSQL_CLIENT --default-character-set=utf8mb4 --local-infile=1 "$@"
    else
        "${COMPOSE[@]}" exec -T "$SERVICE" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 --local-infile=1 "$@"' mysql "$@"
    fi
}

# Where the mysql client sees the CSVs: data/ is mounted at /data in every
# container, or the repo directory itself when MYSQL_CLIENT runs on this machine.
if [[ -n "${MYSQL_CLIENT:-}" ]]; then
    CLIENT_DIR="$DATA"
else
    [[ "$(dirname "$DATA")" == "$ROOT/data" ]] || { echo "DATA_DIR must be a directory directly under data/" >&2; exit 1; }
    CLIENT_DIR="/data/$(basename "$DATA")"
fi

# Parent tables before children.
TABLES=(currencies countries exchange_rates remittance_fees customers kyc_documents
        wallets beneficiaries transactions ledger_entries)

shopt -s nullglob
[[ -f "$DATA/customers.csv" ]] || { echo "No generated data in $DATA — run 'make generate' first." >&2; exit 1; }

echo "Disabling InnoDB redo log and enabling local_infile for the bulk load"
echo "ALTER INSTANCE DISABLE INNODB REDO_LOG; SET GLOBAL local_infile = ON;" | sql
trap 'echo "Re-enabling InnoDB redo log, disabling local_infile"; echo "ALTER INSTANCE ENABLE INNODB REDO_LOG; SET GLOBAL local_infile = OFF;" | sql' EXIT

load_start=$(date +%s)
for table in "${TABLES[@]}"; do
    files=("$DATA/$table"[.]csv "$DATA/${table}"_[0-9][0-9][0-9][0-9].csv)   # globs, so nullglob drops misses
    if (( ${#files[@]} == 0 )); then
        echo "  $table: no CSV found" >&2; exit 1
    fi
    for file in "${files[@]}"; do
        columns="$(head -1 "$file")"
        t0=$(date +%s)
        warnings="$(sql -N "$DB" <<SQL
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION sql_log_bin = 0;
LOAD DATA LOCAL INFILE '$CLIENT_DIR/$(basename "$file")'
    INTO TABLE $table
    CHARACTER SET utf8mb4
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    LINES TERMINATED BY '\n'
    IGNORE 1 LINES
    ($columns);
SELECT @@warning_count;
SQL
)"
        if [[ "$warnings" != "0" ]]; then
            echo "  $table: $(basename "$file") produced $warnings warning(s); rows were rejected. Stopping." >&2
            exit 1
        fi
        printf "  %-18s %-28s %4ss\n" "$table" "$(basename "$file")" "$(( $(date +%s) - t0 ))"
    done
done

echo "Updating index statistics"
sql "$DB" -e "ANALYZE TABLE $(IFS=,; echo "${TABLES[*]}");" > /dev/null

echo "Loaded in $(( $(date +%s) - load_start ))s. Row counts:"
sql "$DB" -t -e "
SELECT table_name, FORMAT(table_rows, 0) AS approx_rows,
       CONCAT(ROUND((data_length + index_length) / 1024 / 1024), ' MB') AS size
  FROM information_schema.tables
 WHERE table_schema = DATABASE()
 ORDER BY data_length + index_length DESC;"
