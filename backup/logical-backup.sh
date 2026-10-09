#!/bin/bash
# Nightly logical backup with MySQL Shell's dump utility: parallel, zstd
# compressed, consistent (backup lock, no FTWRL stall). Portable across
# versions and platforms, and lets single tables be restored, which a physical
# backup can't do on its own.
JOB=logical
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/crypto.sh"
init_crypto
exec 9>/backups/maintenance.lock
flock -n 9 || { echo 'another backup/restore is running' >&2; exit 1; }
[[ ! -e /backups/pitr.active ]] || { echo 'PITR drill is running' >&2; exit 1; }

TARGET="$BACKUP_ROOT/logical/$(stamp)"
STAGE="/run/logical/$(basename "$TARGET")"
mkdir -p "$(dirname "$TARGET")" /run/logical
trap 'rm -rf -- "$STAGE"' EXIT
log "util.dumpSchemas(['payflow', 'ops']) -> $TARGET"
printf '%s\n' "$BACKUP_PASSWORD" | mysqlsh --no-defaults --js --ssl-mode=VERIFY_IDENTITY --ssl-ca=/tls/ca.pem \
    --uri "$BACKUP_USER@$DB_HOST:3306" --passwords-from-stdin \
    -e "util.dumpSchemas(['payflow', 'ops'], '$STAGE', {threads: 4, compression: 'zstd', consistent: true, showProgress: false})" \
    > "$TARGET.log" 2>&1
seal_tree "$STAGE"
mv "$STAGE" "$TARGET"
keep_newest "$BACKUP_ROOT/logical" "$KEEP_LOGICAL"

record success "$(du -sb "$TARGET" | cut -f1)" "$TARGET" \
    "{\"compression\": \"zstd\", \"schemas\": [\"payflow\", \"ops\"]}"
