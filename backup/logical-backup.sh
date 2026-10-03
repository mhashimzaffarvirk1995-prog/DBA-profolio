#!/bin/bash
# Nightly logical backup with MySQL Shell's dump utility: parallel, zstd
# compressed, consistent (backup lock, no FTWRL stall). Portable across
# versions and platforms, and lets single tables be restored, which a physical
# backup can't do on its own.
JOB=logical
source "$(dirname "$0")/lib.sh"

TARGET="$BACKUP_ROOT/logical/$(stamp)"
mkdir -p "$(dirname "$TARGET")"
log "util.dumpSchemas(['payflow', 'ops']) -> $TARGET"
mysqlsh --no-defaults --js --ssl-mode=REQUIRED \
    --uri "$BACKUP_USER@$DB_HOST:3306" --password="$BACKUP_PASSWORD" \
    -e "util.dumpSchemas(['payflow', 'ops'], '$TARGET', {threads: 4, compression: 'zstd', consistent: true, showProgress: false})" \
    > "$TARGET.log" 2>&1
keep_newest "$BACKUP_ROOT/logical" "$KEEP_LOGICAL"

record success "$(du -sb "$TARGET" | cut -f1)" "$TARGET" \
    "{\"compression\": \"zstd\", \"schemas\": [\"payflow\", \"ops\"]}"
