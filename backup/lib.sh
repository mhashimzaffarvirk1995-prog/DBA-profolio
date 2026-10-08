# Shared by the backup jobs. Runs inside the ops container.
set -Eeuo pipefail   # -E: the ERR trap below also fires inside functions

# cron starts jobs with an empty environment and PATH=/usr/bin:/bin (no
# /usr/sbin, where mysqld lives); entrypoint.sh saved the real environment here.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Cron needs the saved environment; interactive runs may deliberately override
# credentials (for example the failed-backup monitoring drill).
if [[ -z "${BACKUP_PASSWORD:-}" && -f /etc/ops.env ]]; then
    source /etc/ops.env
fi
: "${DB_HOST:=mysql}" "${BACKUP_USER:=backup}" "${BACKUP_ROOT:=/backups}"
: "${BACKUP_PASSWORD:?BACKUP_PASSWORD is not set}"
: "${KEEP_FULL:=2}" "${KEEP_LOGICAL:=3}"

# Credentials go in an option file, never on a command line (visible in ps).
CNF="$HOME/.backup.cnf"
umask 077
printf '[client]\nhost=%s\nuser=%s\npassword=%s\nssl-mode=REQUIRED\n' \
    "$DB_HOST" "$BACKUP_USER" "$BACKUP_PASSWORD" > "$CNF"

START=$(date +%s)
stamp()  { date -u +%Y%m%dT%H%M%SZ; }
log()    { echo "$(date -u +%FT%TZ) [$JOB] $*"; }
db()     { mysql --defaults-extra-file="$CNF" -N -B "$@"; }

# record <success|failed> <bytes> <location> [details-json]
# Writes the evidence row and, if a Pushgateway is reachable, the metrics the
# monitoring stack alerts on (Phase 5).
record() {
    local status="$1" bytes="$2" location="$3" details="${4:-}" dur=$(( $(date +%s) - START ))
    [[ -n "$details" ]] || details='{}'
    details="${details//\'/\'\'}"
    db -e "INSERT INTO ops.backup_history (job, status, started_at, finished_at, duration_s, bytes, location, details)
           VALUES ('$JOB', '$status', FROM_UNIXTIME($START), UTC_TIMESTAMP(), $dur, $bytes, '$location', '$details')" \
        || log "WARNING: could not write ops.backup_history"
    push_metrics "$status" "$dur" "$bytes"
    log "$status in ${dur}s, $(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes") at $location"
}

push_metrics() {
    [[ -n "${PUSHGATEWAY_URL:-}" ]] || return 0
    local ok=0; [[ "$1" == success ]] && ok=1
    {
        echo "# TYPE payflow_backup_last_run_timestamp_seconds gauge"
        echo "payflow_backup_last_run_timestamp_seconds $(date +%s)"
        echo "# TYPE payflow_backup_last_status gauge"
        echo "payflow_backup_last_status $ok"
        if (( ok )); then
            echo "# TYPE payflow_backup_last_success_timestamp_seconds gauge"
            echo "payflow_backup_last_success_timestamp_seconds $(date +%s)"
            echo "# TYPE payflow_backup_duration_seconds gauge"
            echo "payflow_backup_duration_seconds $2"
            echo "# TYPE payflow_backup_size_bytes gauge"
            echo "payflow_backup_size_bytes $3"
        fi
    } | curl -fsS --max-time 5 --data-binary @- "$PUSHGATEWAY_URL/metrics/job/payflow_backup/type/$JOB" >/dev/null 2>&1 \
        || true   # monitoring being down must never fail a backup
}

# Any failing command inside a job records one failure and stops the job.
# (With -E the trap is inherited by $(...) subshells; only the main shell records.)
on_error() {
    [[ "$BASHPID" == "$$" ]] || exit 1
    trap - ERR
    record failed 0 "${TARGET:-none}" "{\"error\": \"line $1: $(tr -d '"\\' <<<"$2" | cut -c1-200)\"}"
    exit 1
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# keep_newest <dir> <n>: delete all but the newest n timestamped subdirectories
keep_newest() {
    ls -1d "$1"/2*/ 2>/dev/null | sort | head -n -"$2" | while read -r old; do
        log "retention: removing $old"; rm -rf "$old"
    done
}
