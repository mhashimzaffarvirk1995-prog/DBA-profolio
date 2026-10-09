#!/usr/bin/env bash
# Keys survive container recreation in their own volume. No production data used.
set -euo pipefail
cd "$(dirname "$0")/.."
compose=(docker compose --env-file .env -f security/docker-compose.yml)
q() { "${compose[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --batch "$@"' mysql -e "$1"; }
trap '"${compose[@]}" stop mysql >/dev/null' EXIT
"${compose[@]}" up -d --wait
q "CREATE DATABASE IF NOT EXISTS encryption_demo DEFAULT ENCRYPTION='Y'; CREATE TABLE IF NOT EXISTS encryption_demo.secret (id INT PRIMARY KEY, value VARCHAR(80)) ENCRYPTION='Y'; INSERT IGNORE INTO encryption_demo.secret VALUES(1,'synthetic KYC sentinel'); SELECT NAME,ENCRYPTION FROM information_schema.INNODB_TABLESPACES WHERE NAME='encryption_demo/secret'; SELECT * FROM performance_schema.keyring_component_status;"
"${compose[@]}" up -d --force-recreate --wait mysql
result=$(q "SELECT value FROM encryption_demo.secret WHERE id=1")
[[ "$result" == *'synthetic KYC sentinel'* ]]
q "SELECT @@innodb_redo_log_encrypt,@@innodb_undo_log_encrypt,@@binlog_encryption; SELECT NAME,ENCRYPTION FROM information_schema.INNODB_TABLESPACES WHERE NAME='encryption_demo/secret';"
echo 'PASS: encrypted tablespace readable after container recreation with persistent keyring'
