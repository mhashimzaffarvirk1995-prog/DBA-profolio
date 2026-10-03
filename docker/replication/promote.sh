#!/usr/bin/env bash
# Manual failover for classic replication: promote a replica to primary.
#
#   promote.sh <new-primary> [--rejoin-old]
#
#   1. pick the target (it should be the most up-to-date replica; this script
#      refuses if another running replica has applied transactions it lacks)
#   2. let it apply everything it already received from the old primary
#   3. stop replication on it, make it writable
#   4. repoint every other running server at it (GTID auto-position)
# With --rejoin-old, the old primary, if it is running again, is made
# read-only and attached as a replica of the new one.
#
# This is exactly the work InnoDB Cluster automates; see docs/02-replication-ha.md.
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../../scripts/lib/common.sh"

NEW="${1:?usage: promote.sh <primary|replica1|replica2> [--rejoin-old]}"
REJOIN_OLD="${2:-}"
REPL_PASSWORD="$(env_value REPL_PASSWORD)"
SERVERS=(primary replica1 replica2)
running() { [[ "$(docker inspect -f '{{.State.Running}}' "payflow-$1" 2>/dev/null)" == true ]]; }
running "$NEW" || { echo "$NEW is not running" >&2; exit 1; }
t0=$(date +%s)

step "1. Check $NEW is the most up-to-date replica"
new_gtid="$(q "$NEW" "SELECT @@gtid_executed")"
for s in "${SERVERS[@]}"; do
    [[ "$s" == "$NEW" ]] && continue
    running "$s" || continue
    # Only compare with other replicas; an old primary that is still up is
    # handled (or refused) in step 4.
    [[ "$(q "$s" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration")" == 0 ]] && continue
    missing="$(q "$s" "SELECT GTID_SUBTRACT(@@gtid_executed, '$new_gtid')")"
    if [[ -n "$missing" ]]; then
        echo "$s has transactions $NEW lacks ($missing). Promote $s instead, or let $NEW catch up." >&2
        exit 1
    fi
done
echo "ok: no running replica is ahead of $NEW"

step "2. Apply relay log backlog on $NEW"
# The I/O thread has stopped receiving (old primary is gone); wait for the
# applier to drain what was already downloaded.
received="$(q "$NEW" "SELECT received_transaction_set FROM performance_schema.replication_connection_status" || true)"
if [[ -n "$received" ]]; then
    q "$NEW" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$received', 60)" >/dev/null
fi
echo "applied everything received"

step "3. Promote $NEW"
sql "$NEW" <<SQL
STOP REPLICA;
RESET REPLICA ALL;
SET PERSIST super_read_only = OFF;
SET PERSIST read_only = OFF;
SQL
echo "$NEW is writable"

step "4. Repoint the other servers at $NEW"
for s in "${SERVERS[@]}"; do
    [[ "$s" == "$NEW" ]] && continue
    running "$s" || { echo "$s: down, skipped"; continue; }
    is_replica="$(q "$s" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration")"
    if [[ "$is_replica" == 0 && "$REJOIN_OLD" != "--rejoin-old" ]]; then
        echo "$s: not a replica (old primary?), left alone; rerun with --rejoin-old to attach it"
        continue
    fi
    # An old primary may hold transactions that never reached anyone else
    # ("errant" GTIDs). Attaching it would silently diverge, so refuse.
    errant="$(q "$s" "SELECT GTID_SUBTRACT(@@gtid_executed, '$(q "$NEW" "SELECT @@gtid_executed")')")"
    if [[ -n "$errant" ]]; then
        echo "$s: has errant transactions $errant; rebuild it (clone) instead of attaching" >&2
        continue
    fi
    sql "$s" <<SQL
STOP REPLICA;
SET PERSIST read_only = ON;
SET PERSIST super_read_only = ON;
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST = '$NEW', SOURCE_PORT = 3306,
    SOURCE_USER = 'repl', SOURCE_PASSWORD = '$REPL_PASSWORD',
    SOURCE_AUTO_POSITION = 1, SOURCE_SSL = 1,
    SOURCE_CONNECT_RETRY = 5, SOURCE_RETRY_COUNT = 1000;
START REPLICA;
SQL
    echo "$s now replicates from $NEW"
done

echo
echo "Promotion finished in $(( $(date +%s) - t0 ))s (excluding time to notice the outage and repoint the app)."
"$(dirname "$0")/status.sh"
