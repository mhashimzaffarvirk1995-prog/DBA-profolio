#!/usr/bin/env bash
# Disaster-recovery drill: point-in-time recovery of a dropped table.
#
# Scenario: during business hours someone runs DROP TABLE kyc_documents on
# production. The table is referenced by compliance, so it must come back with
# every row it had at the moment of the drop, including rows added after last
# night's backup, while payments keep flowing.
#
#   0. preflight: a prepared full backup and the binlog archiver are in place
#   1. app traffic: a deposit every 200 ms for the whole drill
#   2. new KYC rows after the backup (they exist only in the binlogs), then
#      record the table's row count and checksum
#   3. the incident: DROP TABLE kyc_documents
#   4. recovery on a separate server, production untouched:
#        restore the full backup -> replay archived binlogs up to the event
#        just before the DROP -> verify -> copy the table back to production
#   5. results: RTO, RPO, app impact; written to ops.backup_history and
#      docs/evidence/
#
# Run via `make pitr-drill` with `make up ops-up` running and a full backup taken.
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")/../docker/standalone" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../scripts/lib/common.sh"

RUN="$(date +%Y%m%d%H%M%S)"
EVIDENCE="$ROOT/docs/evidence/pitr-drill-$RUN.log"
mkdir -p "$(dirname "$EVIDENCE")"
exec > >(tee "$EVIDENCE") 2>&1

ops()  { "${COMPOSE[@]}" exec -T ops "$@"; }
# root over TCP from the ops container; -h makes the target explicit every time
on()   { local host="$1"; shift; ops sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -h $host -uroot -N -B payflow -e \"$*\"" 2>/dev/null; }
now()  { ops date +%s%3N; }
clock(){ ops date -u -d "@$(( $1 / 1000 ))" +%T; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }

step "0. Preflight"
ops test -d /backups/full/latest/ || { echo "No full backup: run 'make backup-full' first" >&2; exit 1; }
read -r backup_file backup_pos backup_gtids < <(ops cat /backups/full/latest/xtrabackup_binlog_info)
backup_dir="$(ops readlink -f /backups/full/latest)"
docker inspect -f '{{.State.Running}}' payflow-binlog-archiver | grep -q true || { echo "binlog archiver not running: make ops-up" >&2; exit 1; }
echo "full backup:  $backup_dir"
echo "taken at:     binlog $backup_file:$backup_pos, GTIDs $backup_gtids"

step "1. Application traffic: one deposit every 200 ms"
wallet="$(on mysql "SELECT w.wallet_id FROM wallets w JOIN customers c USING (customer_id) WHERE c.customer_ref = 'DR-PROBE'")"
if [[ -z "$wallet" ]]; then
    on mysql "INSERT INTO customers (customer_ref, first_name, last_name, email, phone, nationality_country_code, residence_country_code, kyc_status)
              VALUES ('DR-PROBE', 'Drill', 'Probe', 'dr.probe@payflow.example', '+440', 'GB', 'GB', 'verified');
              INSERT INTO wallets (customer_id, currency_code) VALUES (LAST_INSERT_ID(), 'GBP');"
    wallet="$(on mysql "SELECT w.wallet_id FROM wallets w JOIN customers c USING (customer_id) WHERE c.customer_ref = 'DR-PROBE'")"
fi
ops bash -c "touch /tmp/drill.run; n=0; ok=0; export MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\"
    while [ -f /tmp/drill.run ]; do
        n=\$((n+1))
        mysql -h mysql -uroot payflow -e \"CALL sp_deposit($wallet, 1.00, 'api', 'drill-$RUN-\$n', @t)\" 2>/dev/null && ok=\$((ok+1))
        sleep 0.2
    done; echo \"\$n \$ok\" > /tmp/drill.count" &
traffic_pid=$!
echo "deposits running against wallet $wallet"

step "2. KYC activity after the backup (exists only in the binlogs)"
on mysql "INSERT INTO kyc_documents (customer_id, doc_type, doc_number, issuing_country_code, issue_date, expiry_date, status, file_sha256, created_at)
          SELECT customer_id, 'passport', CONCAT('DR', customer_id), 'GB', '2026-01-01', '2036-01-01', 'pending', SHA2(CONCAT('drill-$RUN-', customer_id), 256), UTC_TIMESTAMP(6)
            FROM customers WHERE customer_type = 'individual' ORDER BY customer_id DESC LIMIT 5"
sleep 3
before_rows="$(on mysql "SELECT COUNT(*) FROM kyc_documents")"
before_checksum="$(on mysql "CHECKSUM TABLE kyc_documents" | cut -f2)"
post_backup_rows="$(on mysql "SELECT COUNT(*) FROM kyc_documents WHERE doc_number LIKE 'DR%' AND file_sha256 = SHA2(CONCAT('drill-$RUN-', customer_id), 256)")"
echo "kyc_documents: $before_rows rows (checksum $before_checksum), of which $post_backup_rows added after the backup"

step "3. INCIDENT: DROP TABLE kyc_documents on production"
t_drop="$(now)"
on mysql "DROP TABLE kyc_documents"
echo "dropped at $(clock "$t_drop") UTC; payments keep running"

step "4. Recovery (production stays online)"
t_start="$(now)"

echo "-- 4a. find the DROP in the archived binlogs"
drop_gtid=""
for _ in $(seq 1 60); do
    drop_gtid="$(ops bash -c "mysqlbinlog --base64-output=decode-rows /backups/binlogs/binlog.[0-9]* 2>/dev/null \
        | awk '/GTID_NEXT=/ { g = \$0 } /DROP TABLE .kyc_documents./ { print g; exit }' \
        | grep -o \"'[^']*'\" | tr -d \"'\"")"
    [[ -n "$drop_gtid" ]] && break
    sleep 0.5
done
t_found="$(now)"
[[ -n "$drop_gtid" ]] || { echo "DROP not found in the archive" >&2; exit 1; }
uuid="${drop_gtid%:*}"; seqno="${drop_gtid##*:}"
echo "DROP is GTID $drop_gtid (archived $(secs "$t_drop" "$t_found") s after it ran)"

echo "-- 4b. restore last night's full backup into the recovery volume"
ops bash -c "rm -rf /recovery/* && xtrabackup --copy-back --target-dir=/backups/full/latest --datadir=/recovery >/tmp/copyback.log 2>&1 && chown -R mysql:mysql /recovery"
"${COMPOSE[@]}" --profile recovery up -d recovery >/dev/null 2>&1
wait_healthy payflow-recovery 600
t_restored="$(now)"
echo "recovery server up on the restored backup in $(secs "$t_found" "$t_restored") s"

echo "-- 4c. replay binlogs from the backup position up to (not including) the DROP"
# GTIDs already in the backup are skipped automatically by the server;
# excluding $uuid:$seqno onwards stops exactly before the DROP.
ops bash -c "files=\$(ls /backups/binlogs/binlog.[0-9]* | awk -v f=$backup_file '{ n = split(\$0, p, \"/\"); if (p[n] >= f) print }')
    mysqlbinlog --exclude-gtids='$uuid:$seqno-9999999999' \$files \
      | MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -h recovery -uroot"
t_replayed="$(now)"
recovered_rows="$(on recovery "SELECT COUNT(*) FROM kyc_documents")"
recovered_checksum="$(on recovery "CHECKSUM TABLE kyc_documents" | cut -f2)"
echo "replayed in $(secs "$t_restored" "$t_replayed") s; recovery copy has $recovered_rows rows (checksum $recovered_checksum)"
[[ "$recovered_rows" == "$before_rows" && "$recovered_checksum" == "$before_checksum" ]] \
    || { echo "recovery copy does not match the pre-drop table" >&2; exit 1; }

echo "-- 4d. copy the table back into production"
ops bash -c "export MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\"
    mysqldump -h recovery -uroot --single-transaction --set-gtid-purged=OFF --triggers payflow kyc_documents \
      | mysql -h mysql -uroot payflow"
t_done="$(now)"
after_rows="$(on mysql "SELECT COUNT(*) FROM kyc_documents")"
after_checksum="$(on mysql "CHECKSUM TABLE kyc_documents" | cut -f2)"
triggers="$(on mysql "SELECT COUNT(*) FROM information_schema.triggers WHERE event_object_schema = 'payflow' AND event_object_table = 'kyc_documents'")"
echo "production kyc_documents: $after_rows rows (checksum $after_checksum), $triggers audit triggers restored"

step "5. Results"
ops rm -f /tmp/drill.run
wait "$traffic_pid" || true
read -r attempted committed < <(ops cat /tmp/drill.count)
stored="$(on mysql "SELECT COUNT(*) FROM transactions WHERE idempotency_key LIKE 'drill-$RUN-%'")"
"${COMPOSE[@]}" --profile recovery stop recovery >/dev/null 2>&1
"${COMPOSE[@]}" --profile recovery rm -f recovery >/dev/null 2>&1

lost=$(( before_rows - after_rows ))
match="no"; [[ "$after_checksum" == "$before_checksum" ]] && match="yes"
rto="$(secs "$t_drop" "$t_done")"
cat <<REPORT
incident (DROP TABLE)                 $(clock "$t_drop") UTC
table back in production              $(clock "$t_done") UTC
RTO (drop -> table restored)          ${rto} s
  find DROP in archive                $(secs "$t_start" "$t_found") s
  restore backup + start server       $(secs "$t_found" "$t_restored") s
  replay binlogs to just before DROP  $(secs "$t_restored" "$t_replayed") s
  copy table back to production       $(secs "$t_replayed" "$t_done") s
RPO (KYC rows lost)                   ${lost}   (post-backup rows recovered: $post_backup_rows/$post_backup_rows; checksum identical: $match)
binlog archive lag at the drop        $(secs "$t_drop" "$t_found") s or less
payments during the incident          $committed/$attempted committed, $stored present (production never went down)
REPORT

ops sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -h mysql -uroot -e \"INSERT INTO ops.backup_history (job, status, started_at, finished_at, duration_s, bytes, location, details)
    VALUES ('pitr_drill', '$([[ $lost == 0 && $match == yes ]] && echo success || echo failed)', FROM_UNIXTIME($(( t_drop / 1000 ))), FROM_UNIXTIME($(( t_done / 1000 ))),
            $(( (t_done - t_drop) / 1000 )), 0, '$backup_dir',
            JSON_OBJECT('rto_s', $rto, 'rows_lost', $lost, 'post_backup_rows_recovered', $post_backup_rows, 'drop_gtid', '$drop_gtid', 'checksum_match', '$match'))\"" 2>/dev/null
echo
echo "Evidence: ${EVIDENCE#$ROOT/}"
