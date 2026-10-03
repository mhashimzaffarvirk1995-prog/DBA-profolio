#!/bin/bash
# A backup nobody has restored is a hope, not a backup. Nightly: restore the
# latest full backup into a scratch directory, start a private mysqld on it,
# and check the data is complete and the ledger still balances.
JOB=verify
source "$(dirname "$0")/lib.sh"

SRC="$(readlink -f "$BACKUP_ROOT/full/latest")"
TARGET="$BACKUP_ROOT/verify"
SOCK=/tmp/verify.sock
# Every client call names the local socket explicitly, so nothing here can
# ever reach the production server.
LOCAL=(--no-defaults --host=localhost --socket="$SOCK" --user=root)
rm -rf "$TARGET" /tmp/verify.err; mkdir -p "$TARGET"
log "restoring $SRC into $TARGET"
xtrabackup --copy-back --target-dir="$SRC" --datadir="$TARGET" > "$TARGET.log" 2>&1
chown -R mysql:mysql "$TARGET"

log "starting a private mysqld on the restored copy"
mysqld --no-defaults --user=mysql --datadir="$TARGET" --socket="$SOCK" --skip-networking \
       --skip-grant-tables --skip-log-bin --skip-replica-start --server-id=999 \
       --innodb-buffer-pool-size=256M --log-error=/tmp/verify.err --pid-file=/tmp/verify.pid &
for _ in $(seq 1 120); do mysqladmin "${LOCAL[@]}" ping >/dev/null 2>&1 && break; sleep 1; done
mysqladmin "${LOCAL[@]}" ping >/dev/null 2>&1 || { tail -5 /tmp/verify.err; false; }
vq() { mysql "${LOCAL[@]}" -N -B -e "$1"; }

txns="$(vq "SELECT COUNT(*) FROM payflow.transactions")"
ledger="$(vq "SELECT COUNT(*) FROM payflow.ledger_entries")"
customers="$(vq "SELECT COUNT(*) FROM payflow.customers")"
unbalanced="$(vq "SELECT COUNT(*) FROM (SELECT currency_code FROM payflow.wallets GROUP BY currency_code HAVING SUM(balance) <> 0) x")"
mysqladmin "${LOCAL[@]}" shutdown
wait || true
rm -rf "$TARGET"

if (( txns == 0 || unbalanced != 0 )); then
    log "FAILED: transactions=$txns, unbalanced currencies=$unbalanced"
    record failed 0 "$SRC" "{\"transactions\": $txns, \"unbalanced_currencies\": $unbalanced}"
    exit 1
fi
record success 0 "$SRC" \
    "{\"transactions\": $txns, \"ledger_entries\": $ledger, \"customers\": $customers, \"unbalanced_currencies\": 0}"
