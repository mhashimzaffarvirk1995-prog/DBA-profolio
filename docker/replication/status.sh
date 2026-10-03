#!/usr/bin/env bash
# Replication health for the classic setup.
#
#   status.sh              threads, lag, errors, GTID position per replica
#   status.sh --checksum   also compare table checksums with the current primary
#
# Works whichever server is currently primary (e.g. after promote.sh).
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../../scripts/lib/common.sh"

SERVERS=(primary replica1 replica2)
running() { [[ "$(docker inspect -f '{{.State.Running}}' "payflow-$1" 2>/dev/null)" == true ]]; }

# The primary is the running server that replicates from nobody and is writable.
current_primary=""
for s in "${SERVERS[@]}"; do
    running "$s" || continue
    if [[ "$(q "$s" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration")" == 0 \
          && "$(q "$s" "SELECT @@super_read_only")" == 0 ]]; then
        current_primary="$s"
    fi
done

printf '%-9s %-9s %-4s %-4s %-6s %-9s %s\n' SERVER ROLE IO SQL LAG_S SOURCE "GTID_EXECUTED / LAST ERROR"
for s in "${SERVERS[@]}"; do
    if ! running "$s"; then
        printf '%-9s %-9s %s\n' "$s" DOWN "-"; continue
    fi
    gtid="$(q "$s" "SELECT REPLACE(@@gtid_executed, '\n', '')")"
    if [[ "$s" == "$current_primary" ]]; then
        printf '%-9s %-9s %-4s %-4s %-6s %-9s %s\n' "$s" PRIMARY - - - - "$gtid"
        continue
    fi
    st="$(sql "$s" -e "SHOW REPLICA STATUS\G")"
    field() { awk -F': ' -v k="$1" '$1 ~ "^ *"k"$" {print $2; exit}' <<<"$st"; }
    if [[ -z "$st" ]]; then
        printf '%-9s %-9s %s\n' "$s" STANDALONE "not replicating (read_only=$(q "$s" "SELECT @@read_only"))"; continue
    fi
    err="$(field Last_IO_Error)$(field Last_SQL_Error)"
    printf '%-9s %-9s %-4s %-4s %-6s %-9s %s\n' "$s" REPLICA \
        "$(field Replica_IO_Running)" "$(field Replica_SQL_Running)" \
        "$(field Seconds_Behind_Source)" "$(field Source_Host)" "${err:-$gtid}"
done

if [[ "${1:-}" == "--checksum" && -n "$current_primary" ]]; then
    echo
    echo "Table checksums vs $current_primary (replicas must match exactly):"
    tables="payflow.transactions, payflow.ledger_entries, payflow.wallets, payflow.customers,
            payflow.beneficiaries, payflow.kyc_documents, payflow.audit_log"
    primary_gtid="$(q "$current_primary" "SELECT @@gtid_executed")"
    ref="$(q "$current_primary" "CHECKSUM TABLE $tables")"
    for s in "${SERVERS[@]}"; do
        [[ "$s" == "$current_primary" ]] && continue
        running "$s" || continue
        # Let the replica apply everything the primary had when we took its checksum.
        if [[ "$(q "$s" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$primary_gtid', 60)")" != 0 ]]; then
            echo "  $s: still behind after 60s, not compared"; continue
        fi
        got="$(q "$s" "CHECKSUM TABLE $tables")"
        if [[ "$got" == "$ref" ]]; then
            echo "  $s: identical ($(wc -l <<<"$ref" | tr -d ' ') tables)"
        else
            echo "  $s: DIFFERS"; diff <(echo "$ref") <(echo "$got") | sed 's/^/    /'
        fi
    done
fi
