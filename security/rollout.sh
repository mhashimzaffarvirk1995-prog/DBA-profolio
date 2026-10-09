#!/usr/bin/env bash
# One-time lab transition. Never discard an existing backup before verification.
set -euo pipefail
cd "$(dirname "$0")/.."
compose=(docker compose --env-file .env -f docker/standalone/docker-compose.yml)
if "${compose[@]}" exec -T ops test -f /backups/full/latest/sealed.ok; then
    echo 'Encrypted rollout already applied; use security-verify and backup-verify.'
    exit 0
fi
"${compose[@]}" stop ops binlog-archiver
"${compose[@]}" run --rm --no-deps --entrypoint bash ops -c '
 set -euo pipefail
 source /ops/crypto.sh
 umask 077
 init_crypto
 age --version
'
"${compose[@]}" up -d --wait mysql
"${compose[@]}" --profile ops up -d ops audit-collector
python3 security/manage.py harden
python3 security/manage.py setup
python3 security/manage.py encrypt
"${compose[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' < security/backup-scope.sql
"${compose[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "CREATE TABLE IF NOT EXISTS ops.phase6_pitr_probe (id INT PRIMARY KEY, note VARCHAR(80)) ENCRYPTION=\"Y\"; INSERT IGNORE INTO ops.phase6_pitr_probe VALUES(1,\"pre-backup\"); FLUSH BINARY LOGS;"'
# Migrate existing logical dumps and archived logs only after round-trip equality.
"${compose[@]}" exec -T ops bash -c '
 set -euo pipefail
 umask 077
 source /ops/crypto.sh
 for dir in /backups/logical/2*/; do [[ -d "$dir" ]] && seal_tree "${dir%/}"; done
 for file in /backups/binlogs/binlog.[0-9]*; do
   [[ -f "$file" && "$file" != *.age && "$file" != *.partial ]] || continue
   seal_file "$file"; rm -f -- "$file"
 done
'
"${compose[@]}" exec -T ops /ops/full-backup.sh
"${compose[@]}" --profile ops up -d binlog-archiver
"${compose[@]}" exec -T ops /ops/verify-backup.sh
python3 security/manage.py verify
