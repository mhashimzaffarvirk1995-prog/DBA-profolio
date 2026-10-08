# Phase 5: monitoring and alerting

The monitoring stack tracks the standalone server and classic replication lab with Prometheus, mysqld_exporter, node_exporter, Grafana and Alertmanager. Backup jobs send their outcomes to a Pushgateway. Notifications go to a local webhook log, with firing and resolved states; external paging integrations are not configured.

## Run the stack

Run one database lab at a time. Budget buffer pool plus approximately 1 GB overhead per MySQL server, and keep the combined budget below 80% of host RAM. Use process RSS to verify headroom: an online buffer pool shrink may not return memory to the OS. Restart after shrinking if that memory must be reclaimed, accounting for downtime.

```bash
make env network monitoring-up
make up monitoring-setup            # standalone server
make ops-setup ops-up               # backup jobs and Pushgateway reporting
```

For replication, stop the standalone and ops lab first, then use `make repl-up repl-setup monitoring-setup`. The exporter account is created on the current writable primary and replicates to the replicas. The InnoDB Cluster is not included in this monitoring configuration.

Open Grafana at http://localhost:3000, Prometheus at http://localhost:9090, and Alertmanager at http://localhost:9093. Grafana allows anonymous local viewing; its admin password is generated in `.env`. All published ports bind to localhost.

## What is monitored

- MySQL availability and recent restarts.
- Replication thread state and lag above 30 seconds for one minute.
- Failed backup jobs and full/verify success older than 26 hours.
- Connections above 80%, buffer pool hit rate below 99%, low host disk space and slow query rate.

The [rules](../monitoring/prometheus/alerts.yml) link to operational [runbooks](runbooks.md). Critical alerts route immediately after evaluation; warnings wait ten seconds for grouping. Alertmanager suppresses replication notifications when the same server is down. `make alerts` displays received webhook notifications.

## Validation evidence

The saved [replication drill results](evidence/phase5/alert-drill.md) show `ReplicationLagHigh` firing after 101 seconds and clearing 334 seconds after the lock ended, and `ReplicationStopped` firing after 58 seconds and clearing 28 seconds after restarting the SQL thread. These timings are measured at the Prometheus alert API. The script prints webhook logs, but no notification timing evidence is saved in the table.

Run drills only on the disposable lab: they block replication, stop a database or deliberately fail a backup.

```bash
monitoring/alert-drill.sh replication
monitoring/alert-drill.sh production
```

The final [production drill](evidence/phase5/production-drill-final.log) completed with exit status 0 on 2026-10-08. `BackupFailed` fired after **29 s** and cleared **35 s** after a successful rerun. `MySQLDown` fired after **39 s** and cleared **29 s** after restarting MySQL. Both firing and resolved notifications reached the webhook receiver; the final script waits for delivery before advancing. Detection and resolution timings in the table measure Prometheus state, while webhook timestamps show notification delivery separately.

The earlier production run recorded timings but ended with a trailing parse error because the script was edited during execution. It is retained as historical evidence; the final run above supersedes it.

Docker Compose validation, `promtool check config` (10 rules), `amtool check-config`, shell syntax and dashboard JSON checks passed. Grafana's dashboard was inspected with live server, traffic, connection, buffer-pool and backup panels. [Stack health](evidence/phase5/stack-health.json) records Grafana health and scrape success. A healthy exporter scrape is distinct from `mysql_up`: deliberately stopped lab servers still scrape successfully with `mysql_up = 0`.

### Small-VM settings

The current 3.8 GB VM uses a persisted **768 MB** standalone buffer pool. The Phase 4 configuration remains 2 GB for a larger dedicated host; restore it with `SET PERSIST innodb_buffer_pool_size = 2147483648` only after increasing memory headroom. Grafana has a **512 MB** container limit and `GOMEMLIMIT=384MiB`.

The full-backup job now checks for free space equal to the data directory size plus 20% before starting. This conservative guard was added after a drill filled the shared Docker disk. Incomplete drill output and the unused restore-test copy were removed with approval; a successful full backup was then produced. Explicit backup credential overrides are respected so the wrong-password drill produces an actual authentication failure.

## Limitations

The standalone server is always expected up by `MySQLDown`; stopping it to run another lab produces an expected alert. Replication availability alerts require a successful sample within the previous hour, so never-seen or long-down replicas need separate attention. Backup freshness rules require an existing success metric: they do not detect a job that has never reported. Host disk metrics cover the Docker VM, rather than individual database volumes.

The [OOM incident report](incidents/2026-10-06-oom.md) records the memory-budget failure during setup. The original recovery timestamp was not recorded; the 2026-10-08 verification now supplies a clean recovery evidence trail.

## Completion

Phase 5 completed on 2026-10-08. The final production drill exited successfully, both alert transitions reached the webhook, all six [recovery reconciliation checks](evidence/phase5/recovery-reconciliation.txt) passed with exit status 0, and the [logical backup](evidence/phase5/logical-backup.log) succeeded in 83 seconds. The standalone lab and monitoring stack remain running; the replication lab is stopped to preserve VM memory.
