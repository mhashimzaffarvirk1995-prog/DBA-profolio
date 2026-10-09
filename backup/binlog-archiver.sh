#!/bin/bash
# Raw replication stream lands only in tmpfs. Persistent snapshots are age
# encrypted (including the active log), replaced atomically every second.
JOB=binlog
source "$(dirname "$0")/lib.sh"
trap - ERR
mkdir -p "$BACKUP_ROOT/binlogs" /run/binlogs
recipient=/backup-public/recipient.txt
[[ -s "$recipient" ]] || { echo 'Initialize backup encryption first' >&2; exit 1; }
seal_loop() {
    while true; do
        newest=$(find /run/binlogs -name 'binlog.[0-9]*' -printf '%f\n' | sort | tail -1)
        for file in /run/binlogs/binlog.[0-9]*; do
            [[ -f "$file" ]] || continue
            name=${file##*/}
            rm -f "$BACKUP_ROOT/binlogs/$name.age.partial"
            if age -R "$recipient" -o "$BACKUP_ROOT/binlogs/$name.age.partial" "$file"; then
                mv -f "$BACKUP_ROOT/binlogs/$name.age.partial" "$BACKUP_ROOT/binlogs/$name.age"
                [[ "$name" == "$newest" ]] || rm -f -- "$file"
            else
                log 'ERROR: binlog encryption failed'; return 1
            fi
        done
        sleep 1
    done
}
seal_loop & sealer=$!
streamer=''
cleanup() { kill "$sealer" ${streamer:+"$streamer"} 2>/dev/null || true; wait || true; }
trap cleanup EXIT
trap 'exit 0' TERM INT
cd /run/binlogs
while kill -0 "$sealer" 2>/dev/null; do
    from=$(find "$BACKUP_ROOT/binlogs" -name 'binlog.[0-9]*.age' -printf '%f\n' | sort | tail -1)
    from=${from%.age}
    [[ -n "$from" ]] || from=$(db -e 'SHOW BINARY LOG STATUS' | cut -f1)
    log "TLS-verified stream from $from; plaintext buffer is RAM-only"
    mysqlbinlog --defaults-extra-file="$CNF" --read-from-remote-server --raw --stop-never \
        --connection-server-id=990 --verify-binlog-checksum "$from" & streamer=$!
    wait "$streamer" || log 'stream disconnected; retrying'
    sleep 2
done
log 'ERROR: sealer exited; stopping archive service'
exit 1
