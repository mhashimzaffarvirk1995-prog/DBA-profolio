# Runbooks

What to do when an alert fires. Each section matches the `runbook` link in [monitoring/prometheus/alerts.yml](../monitoring/prometheus/alerts.yml). Commands assume the repo's Docker labs; on real servers the SQL is the same.

Every incident follows the same pattern:

1. **Acknowledge** the alert.
2. **Assess** impact: are payments failing?
3. **Mitigate** first, then find the root cause.
4. **Write an RCA** for anything customer-visible ([example](incidents/2026-10-06-oom.md)).

---

## MySQL down

**Alert:** `MySQLDown` (critical). The exporter can't connect to the server for 30 s.

1. **Is the process alive?**
   ```bash
   docker ps -a --filter name=payflow-mysql      # Exited (137) = killed, usually OOM
   docker logs --tail 50 payflow-mysql
   colima ssh -- sudo dmesg | grep -i "killed process"   # OOM killer?
   ```
2. **If it was killed:** start it with `docker start payflow-mysql`, which `restart: unless-stopped` normally does by itself. InnoDB crash recovery replays the redo log. Watch the log for `ready for connections`.
3. **If it's running but unreachable:** check `max_connections` (`ConnectionsHigh`), a full disk (`DiskSpaceLow`), or credentials (`docker logs payflow-mysqld-exporter`).
4. **Verify the data after any crash:**
   ```bash
   make reconcile         # every check must come back empty
   ```
5. **In the InnoDB Cluster:** a dead primary is replaced automatically within 6–22 s (Phase 2). Check `make cluster-status`, then restart the dead node and it rejoins.

## Replication broken

**Alert:** `ReplicationStopped` (critical). The IO or SQL thread is not running on a replica.

1. **Read the error:**
   ```sql
   SHOW REPLICA STATUS\G      -- Last_IO_Error / Last_SQL_Error
   SELECT * FROM performance_schema.replication_applier_status_by_worker\G
   ```
2. **IO thread** (connecting or authenticating): check the source is up, the network, and the `repl` account and password. Then run `START REPLICA IO_THREAD`.
3. **SQL thread stopped by hand** (maintenance): `START REPLICA SQL_THREAD`.
4. **SQL thread stopped on an error** (duplicate key, missing row): the replica has **diverged**. Do *not* skip the transaction. Rebuild the replica with the Clone plugin (`docker/replication/setup.sh` clones any replica that isn't configured) and find out who wrote to it. `super_read_only` should have prevented that.
5. **Confirm the replica caught up** and matches: `make repl-status` compares table checksums.

## Replication lag

**Alert:** `ReplicationLagHigh` (warning). A replica is more than 30 s behind for 1 minute.

1. **Is the applier blocked or just slow?**
   ```sql
   SELECT id, time, state, info FROM information_schema.processlist WHERE command <> 'Sleep';
   ```
   A long-running query or `LOCK TABLES` on the replica blocks the applier (`Waiting for table metadata lock`). Kill it if it's safe to.
2. **Slow, not blocked:** a big batch on the primary, or a replica with less I/O. Measured in the alert drill: after a 150 s stall, the replica needed several minutes to catch up while writes continued. Apply throughput has little headroom over the primary's write rate. Options: more `replica_parallel_workers`, faster storage, or moving reporting queries off that replica.
3. **While lagging,** stop sending reads that need fresh data (statements, balances) to that replica.

## Backup failed

**Alerts:** `BackupFailed` (critical): the last run of a backup job failed. `BackupStale` (warning): no successful full or verify run in 26 h.

1. **What failed?**
   ```bash
   make backup-status                                     # ops.backup_history: the error is in details
   docker exec payflow-ops tail -50 /backups/cron.log
   docker exec payflow-ops ls /backups/full/              # partial directory left behind?
   ```
2. **Common causes:**
   - wrong or expired `backup` password
   - the server is down
   - backup volume full (`DiskSpaceLow`)
   - XtraBackup and server version mismatch after an upgrade
3. **Fix the cause, then re-run immediately:** `make backup-full backup-verify`. Don't wait for the next night. Until a full backup succeeds, recovery depends on an older backup plus more binlogs.
4. **Check the binlog archiver is still streaming:** `docker logs --tail 5 payflow-binlog-archiver`. While it runs, point-in-time recovery from the previous full backup still works.

## Disk full

**Alert:** `DiskSpaceLow` (critical). Less than 15 % free.

1. **What's growing?**
   ```bash
   colima ssh -- sudo du -sh /var/lib/docker/volumes/*
   ```
   ```sql
   SELECT table_schema, ROUND(SUM(data_length + index_length) / 1e9, 1) AS gb
     FROM information_schema.tables GROUP BY 1;
   SHOW BINARY LOGS;
   ```
2. **Quick wins, safest first:**
   - delete old backup directories beyond retention
   - `PURGE BINARY LOGS BEFORE NOW() - INTERVAL 3 DAY`, but **only** after confirming the archiver has copied them and no replica still needs them
   - remove slow logs left over from tuning runs
3. **Never** delete files inside the MySQL data directory by hand.
4. **Afterwards:** revisit the capacity plan ([Phase 4](04-performance-tuning.md#6-capacity-plan)). Budget is about 3× the database size.

## How to fail over

- **InnoDB Cluster:** automatic. For a planned switchover, use MySQL Shell: `dba.getCluster().setPrimaryInstance('node2:3306')`.
- **Classic replication:** `make repl-promote TARGET=replica1` runs [promote.sh](../docker/replication/promote.sh). It checks for errant GTIDs, drains the relay log, promotes the target, and repoints the others. Then repoint the application.

## How to restore

- **One table, to a point in time:** follow the [PITR drill](03-backup-dr.md#the-drill-drop-table-kyc_documents-at-135555). Restore on a side server, replay binlogs up to the bad GTID, then copy the table back.
- **Whole server:** run `xtrabackup --copy-back` from `/backups/full/latest` into an empty data volume, start MySQL, then replay archived binlogs from the backup's `xtrabackup_binlog_info` position.
