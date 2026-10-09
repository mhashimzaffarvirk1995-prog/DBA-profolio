#!/bin/bash
# Nightly physical backup with Percona XtraBackup (hot: no downtime, no global
# lock for InnoDB). The backup is prepared straight away, so a restore is just
# a copy: that keeps RTO low at the cost of disk.
JOB=full
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/crypto.sh"
init_crypto
# Serialize backup/restore operations: the 4 GB lab has one recovery key volume.
exec 9>/backups/maintenance.lock
flock -n 9 || { echo 'another backup/restore is running' >&2; exit 1; }
[[ ! -e /backups/pitr.active ]] || { echo 'PITR drill is running' >&2; exit 1; }

# Keep headroom for redo and temporary files; fail before consuming the
# database filesystem when backup and MySQL volumes share the same disk.
data_bytes=$(du -sb /var/lib/mysql | cut -f1)
free_bytes=$(df -B1 --output=avail "$BACKUP_ROOT" | tail -1 | tr -d ' ')
required_bytes=$(( data_bytes + data_bytes / 5 ))
if (( free_bytes < required_bytes )); then
    log "insufficient disk space: need ${required_bytes} bytes, have ${free_bytes}"
    false
fi

TARGET="$BACKUP_ROOT/full/$(stamp)"
mkdir -p "$TARGET"
printf '%s\n' '{"path":"/keyring/keys","read_only":true}' > /tmp/component_keyring_file.cnf
log "xtrabackup --backup -> $TARGET"
xtrabackup --defaults-extra-file="$CNF" --backup --component-keyring-config=/tmp/component_keyring_file.cnf --target-dir="$TARGET" --parallel=4 \
    > "$TARGET.log" 2>&1
# Snapshot the keyring separately, encrypted to the backup recovery recipient.
# Rotation must be a maintenance operation, never concurrent with a full backup.
key_hash=$(sha256sum /keyring/keys | cut -d' ' -f1)
cp /keyring/keys /dev/shm/backup-keyring
seal_file /dev/shm/backup-keyring "/key-escrow/$(basename "$TARGET").age"
rm -f /dev/shm/backup-keyring
printf '%s\n' "$(basename "$TARGET")" > "$TARGET/keyring.snapshot"
printf '%s\n' '{"path":"/keyring/keys","read_only":true}' > /tmp/component_keyring_file.cnf
log "xtrabackup --prepare using the keyring component"
xtrabackup --prepare --target-dir="$TARGET" --component-keyring-config=/tmp/component_keyring_file.cnf >> "$TARGET.log" 2>&1

# The binlog file/position/GTID set at the instant of the backup: where
# point-in-time recovery starts replaying from.
read -r binlog_file binlog_pos gtids < "$TARGET/xtrabackup_binlog_info"
[[ "$key_hash" == "$(sha256sum /keyring/keys | cut -d' ' -f1)" ]] || { echo 'keyring changed during backup' >&2; exit 1; }
log "authenticating and sealing every backup data file"
seal_tree "$TARGET"
ln -sfn "$TARGET" "$BACKUP_ROOT/full/latest"
# Retention is applied only after an independent restore succeeds.

record success "$(du -sb "$TARGET" | cut -f1)" "$TARGET" \
    "{\"binlog_file\": \"$binlog_file\", \"binlog_pos\": $binlog_pos, \"gtid_executed\": \"$gtids\", \"tool\": \"$(xtrabackup --version 2>&1 | tail -1 | cut -d' ' -f1-3)\"}"
