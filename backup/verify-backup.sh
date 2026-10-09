#!/bin/bash
# A backup nobody has restored is a hope, not a backup. Nightly: restore the
# latest full backup into a scratch directory, start a private mysqld on it,
# and check the data is complete and the ledger still balances.
JOB=verify
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/crypto.sh"
exec 9>/backups/maintenance.lock
flock -n 9 || { echo 'another backup/restore is running' >&2; exit 1; }
[[ ! -e /backups/pitr.active ]] || { echo 'PITR drill is running' >&2; exit 1; }

SRC="$(readlink -f "$BACKUP_ROOT/full/latest")"
TARGET="$BACKUP_ROOT/verify"
SOCK=/tmp/verify.sock
# Every client call names the local socket explicitly, so nothing here can
# ever reach the production server.
LOCAL=(--no-defaults --host=localhost --socket="$SOCK" --user=root)
rm -rf "$TARGET" /tmp/verify.err; mkdir -p "$TARGET"
log "restoring $SRC into $TARGET"
restore_full "$SRC" "$TARGET"

private_pid=''
cleanup_verify() {
    if [[ -n "$private_pid" ]]; then
        mysqladmin "${LOCAL[@]}" shutdown >/dev/null 2>&1 || kill -TERM "$private_pid" 2>/dev/null || true
        wait "$private_pid" 2>/dev/null || true
    fi
}
trap cleanup_verify EXIT
log "starting a private mysqld on the restored copy"
mysqld --no-defaults --user=mysql --datadir="$TARGET" --socket="$SOCK" --skip-networking \
       --skip-grant-tables --skip-log-bin --skip-replica-start --server-id=999 \
       --innodb-buffer-pool-size=256M --innodb-redo-log-encrypt=ON --innodb-undo-log-encrypt=ON --log-error=/tmp/verify.err --pid-file=/tmp/verify.pid &
private_pid=$!
for _ in $(seq 1 120); do mysql "${LOCAL[@]}" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
mysql "${LOCAL[@]}" -e "SELECT 1" >/dev/null 2>&1 || { tail -5 /tmp/verify.err; false; }
vq() { mysql "${LOCAL[@]}" -N -B -e "$1"; }

txns="$(vq "SELECT COUNT(*) FROM payflow.transactions")"
ledger="$(vq "SELECT COUNT(*) FROM payflow.ledger_entries")"
customers="$(vq "SELECT COUNT(*) FROM payflow.customers")"
unbalanced="$(vq "SELECT COUNT(*) FROM (SELECT currency_code FROM payflow.wallets GROUP BY currency_code HAVING SUM(balance) <> 0) x")"
encrypted="$(vq "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES WHERE NAME LIKE 'payflow/%' AND ENCRYPTION <> 'Y'")"
[[ "$encrypted" == 0 ]] || { echo 'unencrypted restored payflow tablespace' >&2; exit 1; }
mysqladmin "${LOCAL[@]}" shutdown
wait "$private_pid" || true
private_pid=''
rm -rf "$TARGET"

if (( txns == 0 || unbalanced != 0 )); then
    log "FAILED: transactions=$txns, unbalanced currencies=$unbalanced"
    record failed 0 "$SRC" "{\"transactions\": $txns, \"unbalanced_currencies\": $unbalanced}"
    exit 1
fi
keep_newest "$BACKUP_ROOT/full" "$KEEP_FULL"
record success 0 "$SRC" \
    "{\"transactions\": $txns, \"ledger_entries\": $ledger, \"customers\": $customers, \"unbalanced_currencies\": 0}"
