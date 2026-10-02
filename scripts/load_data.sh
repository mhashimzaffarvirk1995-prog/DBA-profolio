#!/usr/bin/env bash
# Bulk-load the generated CSVs (data/generated) into the standalone container.
#
#   scripts/load_data.sh [database]        default: payflow
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
# CHECK constraints are still enforced, so bad data still fails the load.
set -euo pipefail

DB="${1:-payflow}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$ROOT/data/generated"
COMPOSE=(docker compose --env-file "$ROOT/.env" -f "$ROOT/docker/standalone/docker-compose.yml")

sql() {
    if [[ -n "${MYSQL_CLIENT:-}" ]]; then
        $MYSQL_CLIENT --default-character-set=utf8mb4 "$@"
    else
        "${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 "$@"' mysql "$@"
    fi
}

# Parent tables before children.
TABLES=(currencies countries exchange_rates remittance_fees customers kyc_documents
        wallets beneficiaries transactions ledger_entries)

shopt -s nullglob
[[ -f "$DATA/customers.csv" ]] || { echo "No generated data in $DATA — run 'make generate' first." >&2; exit 1; }

# Where the server reads files from (/var/lib/mysql-files/ in the container).
FILE_DIR="$(sql -N -e 'SELECT @@secure_file_priv')"
[[ -n "$FILE_DIR" && "$FILE_DIR" != "NULL" ]] || { echo "secure_file_priv is not set on the server" >&2; exit 1; }

echo "Disabling InnoDB redo log for the bulk load"
echo "ALTER INSTANCE DISABLE INNODB REDO_LOG;" | sql
trap 'echo "Re-enabling InnoDB redo log"; echo "ALTER INSTANCE ENABLE INNODB REDO_LOG;" | sql' EXIT

load_start=$(date +%s)
for table in "${TABLES[@]}"; do
    files=("$DATA/$table"[.]csv "$DATA/${table}"_[0-9][0-9][0-9][0-9].csv)   # globs, so nullglob drops misses
    if (( ${#files[@]} == 0 )); then
        echo "  $table: no CSV found" >&2; exit 1
    fi
    for file in "${files[@]}"; do
        columns="$(head -1 "$file")"
        t0=$(date +%s)
        sql "$DB" <<SQL
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION sql_log_bin = 0;
LOAD DATA INFILE '${FILE_DIR%/}/$(basename "$file")'
    INTO TABLE $table
    CHARACTER SET utf8mb4
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    LINES TERMINATED BY '\n'
    IGNORE 1 LINES
    ($columns);
SQL
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
