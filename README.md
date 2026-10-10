# PayFlow: a production-style MySQL platform for a remittance company

![MySQL 8.4 LTS](https://img.shields.io/badge/MySQL-8.4_LTS-4479A1?logo=mysql&logoColor=white)
![InnoDB Cluster](https://img.shields.io/badge/HA-InnoDB_Cluster-00758F)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.9+-3776AB?logo=python&logoColor=white)
![Phases](https://img.shields.io/badge/phases_done-7_of_8-brightgreen)

PayFlow is a fictional money-transfer company that sends money from the UK, the Gulf, North America and Europe to Pakistan, India, Bangladesh and the Philippines. This repository is its **database layer, designed and operated the way a production DBA team would run it**: a schema that refuses bad money data, high availability with measured failover, backup and recovery, tuning, monitoring, and security evidence. PostgreSQL migration is rehearsed on an isolated legacy dataset. Cloud deployment is the remaining phase.

Everything is reproducible on a laptop with `make`, and every number below was measured, with raw logs in [docs/evidence/](docs/evidence/).

## Key results

| Area | Result |
|---|---|
| **Data integrity** | 10,345,881 transactions and 23,576,467 double-entry ledger lines; all 6 Phase 6 reconciliation checks clean (every currency nets to zero, every wallet matches its ledger) |
| **Concurrency** | 16 threads hammering 8 wallets: **0 deadlocks** with ordered row locking, versus 318 with a naive version under the same load; no money created or lost |
| **Automatic failover** | Primary killed (`SIGKILL`) under live writes: InnoDB Cluster elected a new primary on its own, with a **21–22 s** write outage at default settings (**6.5 s** tuned) |
| **Zero data loss** | **RPO = 0**: 158 of 158 and 152 of 152 acknowledged writes present after failover |
| **Replication** | Replicas seeded by Clone in 6 s, **0 s lag** at ~690 writes/s, table checksums identical to the primary |
| **Performance** | Under a mixed load: "recent activity" screen **15.7 s → 6.7 ms**, fee report **>120 s → 5.6 s**, customer screens 0.5 → 449 per second, payments not slowed |
| **Backup and recovery** | 9.1 GiB encrypted full backup in 345 s; independent restore in 137 s; encrypted PITR with escrowed keys: **124 s, RPO 0** |
| **Security** | Production tablespaces, redo/undo and binlogs encrypted; identity-verified TLS; encrypted full restore and escrow-key PITR (RPO 0); independent metadata audit |
| **Migration** | Isolated PostgreSQL → MySQL: 220,001 payments and 440,002 ledger rows; seven table hashes match; cutover 41.442 s, controlled post-write rollback 14.598 s with zero acknowledged payments lost |
| **Tests** | 46 SQL assertions on procedures and triggers, passing natively and in Docker |
| **Reproducibility** | From empty volumes: replication lab in 38 s, 3-node cluster in 48 s, 10M-row load in 6–8 min |

## Architecture

```mermaid
flowchart LR
  APP([Application]) -- ":6446 writes" --> RT[MySQL Router]
  APP -- ":6447 reads" --> RT
  RT --> N1[(node1<br/>PRIMARY)]
  RT -.-> N2[(node2<br/>secondary)]
  RT -.-> N3[(node3<br/>secondary)]
  N1 <-- "Group Replication:<br/>a majority certifies every commit" --> N2
  N2 <--> N3
  N1 <--> N3
```

Each node holds the same schema: customers, KYC documents, wallets, beneficiaries, FX rates and fees; transactions with a double-entry ledger; and an append-only audit log. Money moves only through stored procedures.

## Roadmap

| # | Phase | What it shows | Status |
|---|---|---|---|
| 1 | [Schema design](docs/01-schema-design.md) | 3NF schema, double-entry ledger, deadlock-free stored procedures, audit triggers, 10M-row realistic dataset | ✅ Done |
| 2 | [Replication and HA](docs/02-replication-ha.md) | GTID replication with scripted manual failover; InnoDB Cluster + Router with measured automatic failover | ✅ Done |
| 3 | [Backup and disaster recovery](docs/03-backup-dr.md) | Nightly XtraBackup + MySQL Shell dumps on cron, continuous binlog archiving, automatic restore verification, PITR drill | ✅ Done |
| 4 | [Performance tuning](docs/04-performance-tuning.md) | Load test, slow log + pt-query-digest, EXPLAIN ANALYZE; query rewrite, online indexes, buffer pool sized from a capacity plan | ✅ Done |
| 5 | [Monitoring](docs/05-monitoring.md) | Prometheus, mysqld_exporter, Grafana; replication, failed-backup and database-down alert drills | ✅ Done |
| 6 | [Security and compliance](docs/06-security-compliance.md) | Scoped roles and locked definers, verified TLS, independent audit, encrypted data/backups and escrow-key PITR | ✅ Done |
| 7 | [Migration](docs/07-migration.md) | PostgreSQL → MySQL; seven-table counts/checksums, write fencing, cutover and post-write rollback | ✅ Done |
| 8 | Cloud | Terraform: Amazon RDS for MySQL with read replica, backups, CloudWatch alarms | Planned; AWS account needed for live deployment |

## What's inside

### Phase 1: a schema that protects money

- **Double-entry ledger.** Every movement posts equal debits and credits, so `SUM(balance)` per currency is always zero. One query proves the books balance.
- **Stored procedures** for deposit, transfer, cross-border send and refund. Each runs as a single transaction and rolls back fully on any error. Each is **idempotent**: a retried request never charges twice. Each **locks wallets in a fixed order**, so opposite transfers can't deadlock.
- **Constraints that do real work.** CHECK constraints stop customer wallets going negative, require every failed transaction to state a reason, and give each transaction type exactly the fields it needs.
- **Audit and immutability.** Triggers record before/after JSON for every sensitive change, mask national IDs, and block edits or deletes on transactions and ledger lines. Corrections are posted as reversals, as in real accounting.
- **A dataset that behaves like a real business.** Two years and 10M transactions, with salary-week and pre-Eid peaks, a growing customer base, failed payouts and refunds, all simulated in time order so every balance reconciles.

### Phase 2: staying up when a server dies

- **Classic replication:** Clone-seeded replicas, GTID auto-positioning, TLS, `super_read_only`, and a [promotion script](docker/replication/promote.sh) that refuses unsafe failovers (replicas that are behind, errant GTIDs).
- **InnoDB Cluster:** built with MySQL Shell's AdminAPI and fronted by MySQL Router, plus a [failover demo](docker/cluster/failover-demo.sh) that kills the primary under write load and reports the outage, the RPO and the rejoin time.
### Phase 3: getting data back

- **Three layers of backup:** a nightly XtraBackup (hot, prepared), a nightly MySQL Shell dump (parallel, zstd), and **continuous encrypted binlog streaming**, scheduled by cron in an [ops container](docker/ops/Dockerfile).
- **Verified every night:** the latest backup is restored to a private server and checked for row counts and ledger balance.
- **[PITR drill](docs/06-security-compliance.md#encryption-and-recoverable-backups):** the current drill drops a disposable ops probe, restores an encrypted full backup with independently recovered keys, and replays encrypted binlogs to the GTID before the drop. It passed in 124 s with RPO 0. The earlier [Phase 3 business-table drill](docs/03-backup-dr.md#the-drill-drop-table-kyc_documents-at-135555) remains historical evidence.
- **Evidence trail:** every run is recorded in `ops.backup_history` for auditors.

### Phase 4: making it fast, with evidence

- **Measure first:** a [load generator](scripts/loadgen.py) runs payments, customer screens and reports together, with the slow log on. `pt-query-digest` showed two queries taking **80 %** of server time.
- **Fix the cause:** the worst query needed no index. An `OR` across two columns forced a 10M-row scan, and a `UNION ALL` rewrite took it from 19.6 s to 5 ms. Five online indexes (`LOCK=NONE`, under 50 s each) fixed the rest.
- **Size memory from data:** a [capacity plan](docs/evidence/phase4/capacity.md) found a 1.3 GB hot working set, so the measured tuning run grew the buffer pool from 1 GB to 2 GB in 1 s. The current small VM uses a persisted 768 MB pool to leave headroom for recovery and monitoring.
- **Check the cost:** payment throughput and latency were measured in every run. They ended slightly better than before, and the worst case improved 3.5×.

- **A tuning decision backed by data:** the [design doc](docs/02-replication-ha.md#failover-results) traces the outage second by second, shows that `expelTimeout=0` cuts it from 21 s to 6.5 s, and explains why a payments system should still keep the safer default.

### Phase 5: monitoring and operational response

![PayFlow Grafana dashboard showing server health, traffic, connections, buffer pool hit rate and backup freshness](docs/images/grafana-overview.jpg)

*Live monitoring after the alert drills. One standalone server is running; the replication lab is stopped to fit the VM memory budget. Red shaded regions mark alert intervals.*

- **Live metrics and dashboards:** Prometheus probes the standalone server and classic replicas, Grafana shows database and host metrics, and backup jobs report outcomes through Pushgateway.
- **Measured alerts:** the final production drill detected a failed backup in **29 s** and a stopped database in **39 s**, with firing and resolved webhook delivery verified. Replication lag and stopped-thread drills are also recorded.
- **Operational safeguards:** memory budgets for the small VM, backup disk-headroom checks, cleanup handlers for interrupted drills, and [alert runbooks](docs/runbooks.md). All six recovery reconciliation checks passed after the final drill.

### Phase 6: securing the data and proving recovery

- **Scoped access:** public procedure roles, a locked definer, remote root locked, restricted backup/exporter accounts and identity-verified TLS.
- **Encrypted recovery:** tablespaces, redo/undo and binlogs encrypted; authenticated full/logical backups and binlog archives; independent restore and escrow-key PITR validated.
- **Independent audit:** SQL operation metadata collected separately, HMAC verification, acknowledged RAM-log rotation and three collector alerts.
- **Review evidence:** [monthly grants inventory](docs/evidence/phase6/access-review-2026-10.md), [technical review](docs/evidence/phase6/technical-review-2026-10.md) and [final validation](docs/evidence/phase6/final-validation.log). Human approval and external custody remain production responsibilities.

### Phase 7: migrating between database engines

- **Native PostgreSQL legacy data:** signed sequences, enums, NUMERIC, TIMESTAMPTZ, JSONB and booleans map into the existing MySQL payment schema.
- **Validation before cutover:** source write locks and a read-only snapshot; parent-first batches; seven full-table SHA-256 digests; all six financial invariants. Deliberately corrupted JSON blocks cutover.
- **Measured recovery:** a post-cutover 0.0001 GBP deposit survives a controlled rollback and final remigration, retaining its original ID and idempotency key. The final application reads it through the routing marker.
- **Bounded scope:** synthetic offline lab, separate databases/volumes/network, verified TLS, encrypted MySQL tables, and no production data replacement. See the [migration report](docs/07-migration.md) for scope and evidence.

## Skills demonstrated

| DBA skill | Where |
|---|---|
| Database design, normalisation, constraints | [schema/01_tables.sql](schema/01_tables.sql) |
| Transactions, isolation, row locking, deadlock avoidance | [schema/02_procedures.sql](schema/02_procedures.sql), [scripts/concurrency_test.py](scripts/concurrency_test.py) |
| Triggers, auditing, data immutability | [schema/03_triggers.sql](schema/03_triggers.sql) |
| Bulk loading and large datasets | [scripts/generate_data.py](scripts/generate_data.py), [scripts/load_data.sh](scripts/load_data.sh) |
| GTID replication, Clone plugin, manual failover | [docker/replication/](docker/replication/) |
| Backup, restore, PITR, binlog archiving, DR drills | [backup/](backup/), [docs/03-backup-dr.md](docs/03-backup-dr.md) |
| InnoDB Cluster, Group Replication, MySQL Router, MySQL Shell | [docker/cluster/](docker/cluster/) |
| Query optimisation, indexing, EXPLAIN ANALYZE, slow log, pt-query-digest, capacity planning | [tuning/](tuning/), [docs/04-performance-tuning.md](docs/04-performance-tuning.md) |
| Monitoring, dashboards, alert routing, incident response | [monitoring/](monitoring/), [docs/05-monitoring.md](docs/05-monitoring.md), [docs/runbooks.md](docs/runbooks.md) |
| Least privilege, TLS, encrypted recovery, independent audit | [security/](security/), [Phase 6](docs/06-security-compliance.md) |
| PostgreSQL → MySQL migration, compatibility, cutover/rollback | [migration/](migration/), [Phase 7](docs/07-migration.md) |
| Testing, reconciliation, evidence-based reporting | [schema/tests/](schema/tests/), [schema/queries/](schema/queries/), [docs/](docs/) |
| Linux, Bash, Docker, automation with `make` | [Makefile](Makefile), [scripts/lib/common.sh](scripts/lib/common.sh) |

## Run it yourself

**You need:** Docker with 4 GB+ memory (Docker Desktop, or [Colima](https://github.com/abiosoft/colima) on a Mac without admin rights), Python 3.9+, and about 35 GB of free disk for the full dataset, encrypted backups and scratch recovery.

**Quick look (about 2 minutes):** start MySQL and run the tests.

```bash
make up                 # MySQL 8.4 in Docker; creates .env with random passwords
make test               # 46 procedure and trigger tests
```

**Full dataset (about 15 minutes):** 10M transactions, then the integrity checks and the slow-query baseline.

```bash
make generate           # ~10M transactions -> data/generated/ (4–5 min)
make setup              # schema + bulk load + triggers
make reconcile          # every check should come back empty
make workload           # time the reporting queries Phase 4 will optimise
pip install -r requirements.txt && make concurrency
```

**High availability labs:** use the 200k-row dataset and run one lab at a time.

```bash
make down                                         # free the single server's memory
make repl-up repl-setup repl-status               # primary + 2 replicas
make repl-promote TARGET=replica1                 # manual failover
make repl-down

make cluster-up cluster-setup                     # InnoDB Cluster + Router
make failover-demo                                # kill the primary under load and measure
make cluster-down
```

**Backup and DR** run on the full-size server:

```bash
make up ops-setup ops-up            # backup account, cron ops container, binlog archiver
make backup-full backup-verify      # nightly jobs on demand
make pitr-drill                     # drop a synthetic ops probe, recover it, measure RTO/RPO
```

**Security and compliance** on the standalone server: see [Phase 6](docs/06-security-compliance.md) for setup, key recovery and measured encrypted recovery. `make security-verify security-controls access-review` reruns the access checks and report. The independent collector records SQL operation metadata, with raw SQL confined to RAM. This is a technical lab; external key custody and human compliance approval remain organizational responsibilities.

**Performance tuning** (needs the venv: `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`):

```bash
make perf-run LABEL=before          # 3-minute mixed load + slow log + pt-query-digest
make tuning-apply                   # online indexes
make perf-run LABEL=after ARGS="--q2 rewrite"
make capacity                       # growth and 12/24-month sizing
```

**PostgreSQL migration rehearsal** (no AWS account needed):

```bash
make migration-drill               # resets isolated fixtures; tests migration and rollback
make migration-up migration-verify # inspect/reverify the retained final state
make migration-down                # stop lab databases; retain volumes and evidence
```

The drill automatically stops its databases on completion to free VM memory.

`make help` lists every command.

## Repository layout

```
schema/                 tables, procedures, triggers, SQL tests, reconciliation and workload queries
docker/standalone/      Phase 1: single MySQL server
docker/replication/     Phase 2a: primary + 2 replicas (setup, status/checksums, promote)
docker/cluster/         Phase 2b: InnoDB Cluster, Router, failover demo
docker/ops/             ops image: XtraBackup, MySQL Shell, Percona Toolkit, mysqlbinlog, cron
backup/                 Phase 3: backup jobs, binlog archiver, verification, PITR drill
tuning/                 Phase 4: perf runs, EXPLAIN ANALYZE capture, indexes, capacity plan
monitoring/             Phase 5: metrics, dashboards, alert rules and lab drills
security/               Phase 6: scoped roles, verified TLS, independent audit and key recovery
migration/              Phase 7: PostgreSQL fixtures, batch migration, cutover/rollback and validation
scripts/                data generator, bulk loader, concurrency test, shared helpers
docs/                   design notes and results per phase
docs/evidence/          raw logs behind the numbers above
```
