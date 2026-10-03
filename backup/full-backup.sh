#!/bin/bash
# Nightly physical backup with Percona XtraBackup (hot: no downtime, no global
# lock for InnoDB). The backup is prepared straight away, so a restore is just
# a copy: that keeps RTO low at the cost of disk.
JOB=full
source "$(dirname "$0")/lib.sh"

TARGET="$BACKUP_ROOT/full/$(stamp)"
mkdir -p "$TARGET"
log "xtrabackup --backup -> $TARGET"
xtrabackup --defaults-extra-file="$CNF" --backup --target-dir="$TARGET" --parallel=4 \
    > "$TARGET.log" 2>&1
log "xtrabackup --prepare"
xtrabackup --prepare --target-dir="$TARGET" >> "$TARGET.log" 2>&1

# The binlog file/position/GTID set at the instant of the backup: where
# point-in-time recovery starts replaying from.
read -r binlog_file binlog_pos gtids < "$TARGET/xtrabackup_binlog_info"
ln -sfn "$TARGET" "$BACKUP_ROOT/full/latest"
keep_newest "$BACKUP_ROOT/full" "$KEEP_FULL"

record success "$(du -sb "$TARGET" | cut -f1)" "$TARGET" \
    "{\"binlog_file\": \"$binlog_file\", \"binlog_pos\": $binlog_pos, \"gtid_executed\": \"$gtids\", \"tool\": \"$(xtrabackup --version 2>&1 | tail -1 | cut -d' ' -f1-3)\"}"
