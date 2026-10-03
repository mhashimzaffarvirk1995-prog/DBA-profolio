#!/bin/bash
# Write probe for the failover demo. Runs inside the tools container.
#
#   probe.sh <wallet_id> <run_id> <seconds> [interval_ms]
#
# Every tick: open a NEW connection to MySQL Router's read/write port, deposit
# 1.00 with a unique idempotency key, and log which server committed it.
# Fresh connections are what an app's pool does after an error, so the log
# shows exactly how long writes were impossible.
#   <epoch_ms> OK   <seq> <server> <txn_id>
#   <epoch_ms> FAIL <seq> <error>
WALLET="$1" RUN="$2" SECONDS_TO_RUN="$3" INTERVAL_MS="${4:-200}"
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
end=$(( $(date +%s) + SECONDS_TO_RUN ))
n=0
while (( $(date +%s) < end )); do
    n=$(( n + 1 ))
    t=$(date +%s%3N)
    if out="$(timeout 10 mysql -h router -P 6446 -uroot -N -B --connect-timeout=2 payflow \
              -e "CALL sp_deposit($WALLET, 1.00, 'api', 'probe-$RUN-$n', @t); SELECT @@hostname, @t" 2>&1)"; then
        echo "$t OK $n $(tr '\t' ' ' <<<"$out")"
    else
        echo "$t FAIL $n $(grep -v 'Using a password' <<<"$out" | tail -1 | cut -c1-90)"
    fi
    sleep "$(awk -v ms="$INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"
done
