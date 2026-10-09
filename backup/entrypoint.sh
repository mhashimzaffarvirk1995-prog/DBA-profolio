#!/bin/bash
# ops container: save the environment for cron jobs, install the schedule,
# run crond in the foreground.
set -euo pipefail
env | grep -E '^(DB_HOST|BACKUP_PASSWORD|PUSHGATEWAY_URL|KEEP_[A-Z]+)=' \
    | sed 's/^/export /; s/=\(.*\)$/="\1"/' > /etc/ops.env
chmod 600 /etc/ops.env
mkdir -p /backups/full /backups/logical /backups/binlogs
crontab /ops/crontab
echo "ops: cron schedule installed"; crontab -l | grep -v '^#'
exec crond -n -s
