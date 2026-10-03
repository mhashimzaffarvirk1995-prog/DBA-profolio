#!/bin/bash
# Continuous binary log archiving: mysqlbinlog connects like a replica and
# writes every binlog to /backups/binlogs as it is produced. With the nightly
# full backup this allows recovery to any point in time, and if the server's
# disk is lost the most that's gone is what hadn't been streamed yet (seconds).
JOB=binlog
source "$(dirname "$0")/lib.sh"
trap - ERR                       # this loop handles its own failures
mkdir -p "$BACKUP_ROOT/binlogs"
cd "$BACKUP_ROOT/binlogs"

while true; do
    # Resume from the newest file we have (re-fetching it whole), or from the
    # oldest binlog the server still has.
    from="$(ls -1 binlog.[0-9]* 2>/dev/null | sort | tail -1 || true)"
    [[ -n "$from" ]] || from="$(db -e "SHOW BINARY LOGS" 2>/dev/null | head -1 | cut -f1 || true)"
    if [[ -z "$from" ]]; then
        log "server not reachable, retrying in 5s"; sleep 5; continue
    fi
    log "streaming from $from"
    mysqlbinlog --defaults-extra-file="$CNF" --read-from-remote-server --raw --stop-never \
        --connection-server-id=990 --verify-binlog-checksum "$from" \
        || log "stream ended (exit $?), reconnecting in 5s"
    sleep 5
done
