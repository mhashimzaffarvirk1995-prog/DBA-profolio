#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker exec payflow-ops bash /ops/rotate-audit.sh
echo 'PASS: raw RAM log rotated only after independent collector acknowledgement'
docker exec payflow-audit-collector python /app/audit-tests.py
docker exec payflow-audit-collector wget -qO- http://127.0.0.1:9105/metrics
docker exec payflow-prometheus promtool check config /etc/prometheus/prometheus.yml
docker exec payflow-prometheus wget -qO- 'http://mysqld-exporter:9104/probe?target=mysql:3306&auth_module=client.production' > /tmp/payflow-phase6-metrics.txt
rg '^mysql_up |^mysql_exporter_last_scrape_error' /tmp/payflow-phase6-metrics.txt
