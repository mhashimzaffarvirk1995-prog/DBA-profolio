#!/usr/bin/env bash
# One measured performance run, identical before and after tuning:
#   warm-up 60 s -> slow log on (long_query_time 0.1 s) -> loadgen 180 s ->
#   slow log off -> pt-query-digest report
# Results land in docs/evidence/phase4/<label>-*.
#
#   tuning/perf-run.sh <label> [extra loadgen args, e.g. --q2 rewrite]
set -euo pipefail
# A laptop that sleeps mid-run pauses the Docker VM and ruins the numbers (it
# happened once: a 17-minute gap in the slow log). Keep macOS awake.
if [[ "$(uname)" == Darwin && -z "${PERF_AWAKE:-}" ]] && command -v caffeinate >/dev/null; then
    PERF_AWAKE=1 exec caffeinate -i "$0" "$@"
fi
COMPOSE_FILE="$(cd "$(dirname "$0")/../docker/standalone" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../scripts/lib/common.sh"
LABEL="${1:?usage: perf-run.sh <label> [loadgen args]}"; shift
OUT="$ROOT/docs/evidence/phase4"; mkdir -p "$OUT"
PY="$ROOT/.venv/bin/python"
[[ -x "$PY" ]] || { echo "Run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2; exit 1; }

step "warm-up (60 s, not measured)"
"$PY" "$ROOT/scripts/loadgen.py" --duration 60 "$@" > /dev/null

step "measured run: $LABEL"
sql mysql -e "SET GLOBAL slow_query_log = OFF;
              SET GLOBAL slow_query_log_file = '/var/lib/mysql/slow-$LABEL.log';
              SET GLOBAL long_query_time = 0.1; SET GLOBAL log_slow_extra = ON;
              SET GLOBAL slow_query_log = ON;"
"$PY" "$ROOT/scripts/loadgen.py" --duration 180 --label "$LABEL" --out "$OUT/$LABEL-load.json" "$@" \
    | tee "$OUT/$LABEL-load.txt"
sql mysql -e "SET GLOBAL slow_query_log = OFF"

step "pt-query-digest"
docker run --rm -v payflow_mysql-data:/var/lib/mysql:ro payflow-ops:8.4 \
    pt-query-digest --no-version-check --limit 10 "/var/lib/mysql/slow-$LABEL.log" 2>/dev/null > "$OUT/$LABEL-digest.txt"
# The ranking table at the top of the report
sed -n '/^# Profile/,/^$/p' "$OUT/$LABEL-digest.txt"
echo "saved: docs/evidence/phase4/$LABEL-{load.json,load.txt,digest.txt}"
