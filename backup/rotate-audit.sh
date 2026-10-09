#!/bin/bash
JOB=audit
source "$(dirname "$0")/lib.sh"
trap - ERR
exec 8>/backups/audit-rotation.lock
flock -n 8 || exit 0
file=/run/audit/mysql.log
[[ -f "$file" ]] || exit 0
# Acknowledge the old inode only after all bytes are durably collected.
old=/run/audit/mysql.log.rotated
if [[ -f "$old" ]]; then
    # Resume an interrupted rotation; never discard an unacknowledged RAM log.
    inode=$(stat -c %i "$old")
    if [[ -s /run/audit/rotation-token ]]; then
        token=$(cat /run/audit/rotation-token)
    else
        token=$(cat /proc/sys/kernel/random/uuid)
        printf '%s\n' "$token" > /run/audit/rotation-token
    fi
else
    inode=$(stat -c %i "$file")
    token=$(cat /proc/sys/kernel/random/uuid)
    printf '%s\n' "$token" > /run/audit/rotation-token
    mv "$file" "$old"
fi
db -e 'FLUSH GENERAL LOGS'
for _ in $(seq 1 30); do
    if [[ -f "/audit-events/ack-$inode" ]] && grep -q "^$token " "/audit-events/ack-$inode"; then
        rm -f "$old"
        exit 0
    fi
    sleep 1
done
echo 'audit collector did not acknowledge rotation; retained raw RAM buffer' >&2
exit 1
