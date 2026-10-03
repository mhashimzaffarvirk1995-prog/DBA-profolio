#!/usr/bin/env bash
# Automatic failover demo for the InnoDB Cluster. Good to screen-record.
#
#   failover-demo.sh [seconds]        default 60
#
#   1. start a write probe through MySQL Router (a deposit every 200 ms)
#   2. after 10 s, SIGKILL the current primary's container (a crash, not a
#      clean shutdown)
#   3. report how long writes failed and which node took over
#   4. check every acknowledged write is in the database (RPO)
#   5. restart the killed node and time how long it takes to rejoin
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../../scripts/lib/common.sh"
DURATION="${1:-60}"
LOG_DIR="$ROOT/docs/evidence"; mkdir -p "$LOG_DIR"

tools() { "${COMPOSE[@]}" exec -T tools "$@"; }
via_router() { tools sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -h router -P 6446 -uroot -N -B payflow -e \"$1\"" 2>/dev/null; }
now_ms() { tools date +%s%3N; }

step "0. Cluster before"
"$(dirname "$0")/status.sh"

# A dedicated customer and wallet for the probe, so its deposits are easy to count.
wallet="$(via_router "SELECT w.wallet_id FROM wallets w JOIN customers c USING (customer_id) WHERE c.customer_ref = 'FAILOVER-PROBE'")"
if [[ -z "$wallet" ]]; then
    via_router "INSERT INTO customers (customer_ref, first_name, last_name, email, phone, nationality_country_code, residence_country_code, kyc_status)
                VALUES ('FAILOVER-PROBE', 'Failover', 'Probe', 'failover.probe@payflow.example', '+440', 'GB', 'GB', 'verified');
                INSERT INTO wallets (customer_id, currency_code) VALUES (LAST_INSERT_ID(), 'GBP');"
    wallet="$(via_router "SELECT w.wallet_id FROM wallets w JOIN customers c USING (customer_id) WHERE c.customer_ref = 'FAILOVER-PROBE'")"
fi

RUN="$(date +%Y%m%d%H%M%S)"
LOG="$LOG_DIR/failover-$RUN.log"
step "1. Write probe: one deposit every 200 ms for ${DURATION}s through router:6446"
tools /cluster/probe.sh "$wallet" "$RUN" "$DURATION" 200 > "$LOG" &
probe_pid=$!
sleep 10

victim="$(via_router "SELECT @@hostname")"
step "2. Kill the primary ($victim) with SIGKILL"
kill_ms="$(now_ms)"
docker kill "payflow-$victim" > /dev/null
echo "killed payflow-$victim at $(tools date -d "@$(( kill_ms / 1000 ))" +%T)"

wait "$probe_pid"

step "3. What the application saw"
awk -v kill="$kill_ms" '
    $2 == "OK"   { ok++; if ($1 < kill) { before = $4 } else if (!first_ok) { first_ok = $1; after = $4 } }
    $2 == "FAIL" { fail++; if (!first_fail) { first_fail = $1 }; if (!err) { $1 = $2 = $3 = ""; err = $0 } }
    END {
        printf "writes attempted %d, committed %d, failed %d\n", ok + fail, ok, fail
        printf "primary before: %s   primary after: %s\n", before, after
        if (first_ok) printf "write outage: %.1f s (from kill to first committed write on the new primary)\n", (first_ok - kill) / 1000
        if (err) printf "typical error during the outage:%s\n", err
    }' "$LOG" | tee "$LOG.summary"

step "4. Did every acknowledged write survive?"
acknowledged="$(awk '$2 == "OK"' "$LOG" | wc -l | tr -d ' ')"
stored="$(via_router "SELECT COUNT(*) FROM transactions WHERE idempotency_key LIKE 'probe-$RUN-%'")"
echo "acknowledged by the database: $acknowledged   present after failover: $stored" | tee -a "$LOG.summary"
# A write that failed with a lost connection may still have committed (the
# client just never heard back). The idempotency key settles it.
ambiguous="$(awk '$2 == "FAIL" { print "'"'"'probe-'"$RUN"'-" $3 "'"'"'" }' "$LOG" | paste -sd, -)"
if [[ -n "$ambiguous" ]]; then
    late="$(via_router "SELECT COUNT(*) FROM transactions WHERE idempotency_key IN ($ambiguous)")"
    echo "of the failed attempts, $late committed anyway (safe to retry: same idempotency key returns the original)" | tee -a "$LOG.summary"
fi
if (( stored >= acknowledged )); then
    echo "RPO = 0: no acknowledged write was lost" | tee -a "$LOG.summary"
else
    echo "LOST $(( acknowledged - stored )) acknowledged writes" | tee -a "$LOG.summary"
fi

step "5. Restart $victim and let it rejoin"
start_s=$(date +%s)
docker start "payflow-$victim" > /dev/null
until "${COMPOSE[@]}" exec -T tools mysqlsh --no-defaults --js --file /cluster/status.js 2>/dev/null \
        | grep -q "^$victim:3306 .*ONLINE"; do
    (( $(date +%s) - start_s > 180 )) && { echo "$victim did not rejoin within 180s" >&2; break; }
    sleep 2
done
echo "$victim back ONLINE as a secondary after $(( $(date +%s) - start_s ))s (container start + crash recovery + catch-up)" | tee -a "$LOG.summary"
"$(dirname "$0")/status.sh"
echo
echo "Probe log: ${LOG#$ROOT/}"
