#!/usr/bin/env bash
# Alert drill: cause each failure on purpose, time how long the alert takes to
# fire, fix it, and time how long until it resolves. Proves the alerts work
# end to end (Prometheus -> Alertmanager -> notification), not just that the
# rules parse.
#
#   monitoring/alert-drill.sh replication   # lag + stopped thread (replication lab running)
#   monitoring/alert-drill.sh production    # failed backup + server down (standalone + ops running)
#
# Results are appended to docs/evidence/phase5/alert-drill.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROM=http://127.0.0.1:9090
OUT="$ROOT/docs/evidence/phase5/alert-drill.md"
mkdir -p "$(dirname "$OUT")"
REPL=(docker compose --env-file "$ROOT/.env" -f "$ROOT/docker/replication/docker-compose.yml")
PROD=(docker compose --env-file "$ROOT/.env" -f "$ROOT/docker/standalone/docker-compose.yml")
restore_mysql=0
restore_replica=0
cleanup() {
    if (( restore_mysql )); then docker start payflow-mysql >/dev/null || true; fi
    if (( restore_replica )); then repl_sql replica2 -e "START REPLICA SQL_THREAD" || true; fi
    if [[ -n "${load:-}" ]]; then kill "$load" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

state() {  # state <alertname> <instance-or-type> -> firing|pending|none
    curl -fsS --max-time 10 "$PROM/api/v1/alerts" | python3 -c "
import json, sys
for a in json.load(sys.stdin)['data']['alerts']:
    l = a['labels']
    if l['alertname'] == '$1' and '$2' in (l.get('instance'), l.get('type')):
        print(a['state']); break
else:
    print('none')"
}
wait_for() {  # wait_for <alert> <label> <firing|none> <timeout s> -> prints seconds waited
    local t0=$SECONDS
    until [[ "$(state "$1" "$2")" == "$3" ]]; do
        (( SECONDS - t0 > $4 )) && { echo "TIMEOUT"; return 1; }
        sleep 2
    done
    echo $(( SECONDS - t0 ))
}
wait_notification() {  # alert, label, FIRING|RESOLVED, earliest epoch
    local t0=$SECONDS
    until docker exec payflow-alert-log python -c '
import sys
from datetime import datetime
alert, label, status, since = sys.argv[1:]
with open("/log/alerts.log") as f:
    for line in f:
        fields = line.split()
        if len(fields) >= 5 and fields[1] == status and fields[3:5] == [alert, label]:
            if datetime.fromisoformat(fields[0].replace("Z", "+00:00")).timestamp() >= int(since):
                sys.exit(0)
sys.exit(1)
' "$1" "$2" "$3" "$4"; do
        (( SECONDS - t0 > 180 )) && { echo "notification TIMEOUT: $1 $3" >&2; return 1; }
        sleep 2
    done
}
row() { printf '| %s | %s | %s | %s s | %s s |\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" | tee -a "$OUT"; }
[[ -s "$OUT" ]] || printf '| Time (UTC) | Scenario | Alert | Fired after | Resolved after fix |\n|---|---|---|---|---|\n' > "$OUT"

repl_sql() { local s="$1"; shift; "${REPL[@]}" exec -T "$s" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N "$@"' mysql "$@" 2>/dev/null; }

case "${1:-}" in
replication)
    wait_for ReplicationLagHigh replica1 none 180 >/dev/null
    wait_for ReplicationStopped replica2 none 180 >/dev/null
    echo "== write load on the primary for the whole drill"
    "$ROOT/.venv/bin/python" "$ROOT/scripts/loadgen.py" --port 3311 --app 4 --screens 0 --reports 0 --duration 420 >/dev/null 2>&1 &
    load=$!
    sleep 10

    echo "== 1. replica1 falls behind: a long read lock blocks its applier"
    # The lock ends by itself after 150 s (the session's SLEEP returns).
    repl_sql replica1 -e "LOCK TABLES payflow.wallets READ, payflow.transactions READ, payflow.ledger_entries READ; SELECT SLEEP(150);" >/dev/null &
    lock=$!
    fired="$(wait_for ReplicationLagHigh replica1 firing 150)"
    echo "   ReplicationLagHigh fired after ${fired}s; waiting for the lock to end"
    wait "$lock" || true
    resolved="$(wait_for ReplicationLagHigh replica1 none 900)"   # catch-up under load is slow; measured
    row "replica1 applier blocked by a table lock under write load" ReplicationLagHigh "$fired" "$resolved"

    echo "== 2. replica2's SQL thread stops"
    restore_replica=1
    repl_sql replica2 -e "STOP REPLICA SQL_THREAD"
    fired="$(wait_for ReplicationStopped replica2 firing 180)"
    echo "   ReplicationStopped fired after ${fired}s; restarting the thread"
    repl_sql replica2 -e "START REPLICA SQL_THREAD"
    restore_replica=0
    resolved="$(wait_for ReplicationStopped replica2 none 180)"
    row "STOP REPLICA SQL_THREAD on replica2" ReplicationStopped "$fired" "$resolved"

    kill "$load" 2>/dev/null || true; wait "$load" 2>/dev/null || true
    ;;
production)
    # Require a healthy baseline so a pre-existing alert cannot produce a
    # misleading zero-second detection result.
    wait_for BackupFailed full none 180 >/dev/null
    wait_for MySQLDown mysql none 180 >/dev/null
    since=$(date +%s)
    echo "== 1. nightly backup fails (backup account password wrong)"
    "${PROD[@]}" exec -T -e BACKUP_PASSWORD=wrong-password ops /ops/full-backup.sh >/dev/null 2>&1 || true
    fired="$(wait_for BackupFailed full firing 120)"
    wait_notification BackupFailed full FIRING "$since"
    echo "   BackupFailed fired after ${fired}s; rerunning the backup correctly"
    "${PROD[@]}" exec -T ops /ops/full-backup.sh >/dev/null 2>&1
    resolved="$(wait_for BackupFailed full none 120)"
    wait_notification BackupFailed full RESOLVED "$since"
    row "full backup run with a wrong password" BackupFailed "$fired" "$resolved"

    echo "== 2. production server stops"
    since=$(date +%s)
    restore_mysql=1
    docker stop payflow-mysql >/dev/null
    fired="$(wait_for MySQLDown mysql firing 180)"
    wait_notification MySQLDown mysql FIRING "$since"
    echo "   MySQLDown fired after ${fired}s; starting it again"
    docker start payflow-mysql >/dev/null
    restore_mysql=0
    resolved="$(wait_for MySQLDown mysql none 300)"
    wait_notification MySQLDown mysql RESOLVED "$since"
    row "docker stop payflow-mysql" MySQLDown "$fired" "$resolved"
    ;;
*)
    echo "usage: $0 replication|production" >&2; exit 1 ;;
esac
echo
echo "Notifications received (monitoring/alert-log):"
docker exec payflow-alert-log tail -8 /log/alerts.log
