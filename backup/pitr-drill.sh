#!/usr/bin/env bash
# Phase 6 PITR: drop only a synthetic probe, never a business table. Recover the
# encrypted full backup using escrowed keys, then replay age-encrypted binlogs.
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")/../docker/standalone" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../scripts/lib/common.sh"
EVIDENCE="${PITR_EVIDENCE:-$ROOT/docs/evidence/phase6/encrypted-pitr.log}"
exec > >(tee "$EVIDENCE") 2>&1
ops() { "${COMPOSE[@]}" exec -T ops "$@"; }
now() { python3 -c 'import time; print(int(time.time()*1000))'; }
verified=0
owns_marker=0
cleanup() {
    (( owns_marker )) || return 0
    local stopped=0
    if "${COMPOSE[@]}" --profile recovery stop recovery >/dev/null 2>&1; then stopped=1; fi
    if (( verified && stopped )); then
        ops find /recovery -mindepth 1 -maxdepth 1 -exec rm -rf -- '{}' + >/dev/null 2>&1 || true
    fi
    ops find /run/pitr -mindepth 1 -maxdepth 1 -delete >/dev/null 2>&1 || true
    ops rm -f /backups/pitr.active >/dev/null 2>&1 || true
}
trap cleanup EXIT
# Marker is installed under the same lock backup jobs use, and checked by jobs
# after acquiring that lock. It keeps cron out during the multi-container drill.
ops bash -c 'set -euo pipefail; exec 9>/backups/maintenance.lock; flock -n 9; test ! -e /backups/pitr.active; touch /backups/pitr.active'
owns_marker=1
start=$(now)
q mysql "CREATE TABLE IF NOT EXISTS ops.phase6_pitr_probe (id INT PRIMARY KEY, note VARCHAR(80)) ENCRYPTION='Y'; INSERT IGNORE INTO ops.phase6_pitr_probe VALUES(1,'pre-backup')"
q mysql "SELECT COUNT(*) FROM ops.phase6_pitr_probe WHERE id=1" | grep -qx 1
ops test -f /backups/full/latest/sealed.ok
q mysql "INSERT INTO ops.phase6_pitr_probe VALUES(2,'post-backup PITR sentinel') ON DUPLICATE KEY UPDATE note=VALUES(note)"
expected=$(q mysql 'CHECKSUM TABLE ops.phase6_pitr_probe' | cut -f2)
file=$(q mysql 'SHOW BINARY LOG STATUS' | cut -f1)
before=$(q mysql 'SELECT @@GLOBAL.gtid_executed')
q mysql 'DROP TABLE ops.phase6_pitr_probe'
after=$(q mysql 'SELECT @@GLOBAL.gtid_executed')
drop_gtid=$(q mysql "SELECT GTID_SUBTRACT('$after','$before')")
[[ "$drop_gtid" =~ ^[a-f0-9-]+:[0-9]+$ ]] || { echo 'Concurrent write during probe DROP; refusing ambiguous recovery' >&2; exit 1; }
uuid=${drop_gtid%:*}; seqno=${drop_gtid##*:}
q mysql 'FLUSH BINARY LOGS'
echo "Synthetic incident: DROP ops.phase6_pitr_probe ($drop_gtid)"
# The archiver removes a closed RAM file only after publishing its final sealed
# copy. Wait for that acknowledgement, not just an earlier active-log snapshot.
for _ in $(seq 1 60); do
    if ops test -f "/backups/binlogs/$file.age" && \
       "${COMPOSE[@]}" exec -T binlog-archiver test ! -f "/run/binlogs/$file"; then break; fi
    sleep 1
done
ops test -f "/backups/binlogs/$file.age"
"${COMPOSE[@]}" exec -T binlog-archiver test ! -f "/run/binlogs/$file"
echo 'Encrypted archive contains the closed incident binlog'
"${COMPOSE[@]}" --profile recovery stop recovery >/dev/null 2>&1 || true
ops bash -c 'set -euo pipefail; umask 077; source /ops/crypto.sh; find /recovery -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; restore_full /backups/full/latest /recovery; rm -f /recovery/mysqld-auto.cnf'
"${COMPOSE[@]}" --profile recovery up -d --wait recovery
read -r backup_file backup_pos backup_gtids < <(ops cat /backups/full/latest/xtrabackup_binlog_info)
# Decrypt only the required small, recent binlogs into RAM in ops.
ops bash -s -- "$backup_file" "$file" <<'INNER'
set -euo pipefail
umask 077
mkdir -p /run/pitr
for encrypted in /backups/binlogs/binlog.[0-9]*.age; do
    name=${encrypted##*/}; name=${name%.age}
    [[ "$name" < "$1" || "$name" > "$2" ]] && continue
    age -d -i /backup-identity/key.txt -o "/run/pitr/$name.partial" "$encrypted"
    mv "/run/pitr/$name.partial" "/run/pitr/$name"
done
[[ -f "/run/pitr/$1" && -f "/run/pitr/$2" ]]
INNER
ops bash -c 'mysqlbinlog --verify-binlog-checksum --start-position="$2" --exclude-gtids="$1" /run/pitr/binlog.[0-9]*' \
    pitr "$uuid:$seqno-999999999999" "$backup_pos" | \
    "${COMPOSE[@]}" exec -T recovery sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot'
actual=$(q recovery 'CHECKSUM TABLE ops.phase6_pitr_probe' | cut -f2)
rows=$(q recovery 'SELECT COUNT(*) FROM ops.phase6_pitr_probe')
[[ "$actual" == "$expected" && "$rows" == 2 ]]
echo 'PASS: recovered both pre-backup and post-backup rows; checksum matches'
q recovery "SELECT STATUS_KEY,STATUS_VALUE FROM performance_schema.keyring_component_status; SELECT COUNT(*) AS unencrypted_payflow_spaces FROM information_schema.INNODB_TABLESPACES WHERE NAME LIKE 'payflow/%' AND ENCRYPTION <> 'Y'"
# Put the disposable probe back so the same drill can be run again after a new
# backup. No real business table was dropped or copied.
"${COMPOSE[@]}" exec -T recovery sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --set-gtid-purged=OFF --skip-lock-tables ops phase6_pitr_probe' | \
    "${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot ops'
finish=$(now)
secs=$(( (finish-start)/1000 ))
q mysql "INSERT INTO ops.backup_history (job,status,started_at,finished_at,duration_s,bytes,location,details) VALUES ('pitr_drill','success',FROM_UNIXTIME($((start/1000))),UTC_TIMESTAMP(),$secs,0,'encrypted phase6 recovery',JSON_OBJECT('rto_s',$secs,'rows_lost',0,'checksum_match',true,'escrow_key_recovery',true))"
verified=1
echo "PASS: encrypted full backup + independently recovered keyring + encrypted binlog replay; RPO=0, drill=${secs}s"
# EXIT cleanup empties the RAM mount; the mount point itself cannot be removed.
