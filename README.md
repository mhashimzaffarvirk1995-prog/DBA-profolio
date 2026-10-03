# PayFlow — operating a remittance platform's MySQL database

PayFlow is a fictional money-transfer company, in the style of a UK/Gulf-to-Pakistan remittance provider. This repository is its database layer, built and run the way a production DBA team would: schema and transactional integrity, high availability, backup and point-in-time recovery, performance tuning, monitoring, security and compliance evidence, migration, and cloud deployment.

Every phase is reproducible from this repo on a laptop with Docker.

## Status

| Phase | What it covers | Status |
|---|---|---|
| 1. [Schema design](docs/01-schema-design.md) | Normalised MySQL 8.4 schema, double-entry ledger, stored procedures with deadlock-free locking, audit triggers, 10M-transaction dataset | **Done** |
| 2. [Replication and HA](docs/02-replication-ha.md) | Primary + 2 replicas (GTID, clone-seeded) with scripted manual failover; InnoDB Cluster + MySQL Router with measured automatic failover | **Done** |
| 3. Backup and DR | XtraBackup nightly full, MySQL Shell dumps, binlog archiving, PITR drill with measured RPO/RTO | Planned |
| 4. Performance tuning | Slow log + pt-query-digest, sysbench load, the five worst queries fixed, before/after numbers | Planned |
| 5. Monitoring | Prometheus, mysqld_exporter, Grafana dashboards, alerts on replication lag and failed backups | Planned |
| 6. Security and compliance | Least-privilege roles, TLS, password policy, audit log, encryption at rest, monthly privilege-review report | Planned |
| 7. Migration | Legacy PostgreSQL → MySQL with row-count and checksum validation | Planned |
| 8. Cloud | Terraform: RDS MySQL + read replica, automated backups, CloudWatch alarms, snapshot restore | Planned |
| Ongoing | Health-check, backup-verification and provisioning scripts; runbooks; incident RCA | Planned |

## Phase 2 at a glance

- **Classic replication:** replicas are seeded with the Clone plugin (6 s) and use GTID auto-positioning, `super_read_only` and TLS. Lag stayed at 0 s under ~690 writes/s, and `CHECKSUM TABLE` matched exactly. A scripted manual failover checks for errant GTIDs before attaching anything.
- **InnoDB Cluster:** three Group Replication nodes built with MySQL Shell's AdminAPI, with MySQL Router in front.
- **Failover, measured:** a write probe ran through Router while the primary was `SIGKILL`ed. The cluster elected a new primary automatically, the write outage was **21–22 s at default settings (two runs) (6.5 s with `expelTimeout=0`)**, and **RPO was 0**: every acknowledged write was present afterwards. The killed node rejoined by itself in about 20 s. Raw logs are in [docs/evidence/](docs/evidence/).

## Phase 1 at a glance

- **10 tables in 3NF** covering customers, KYC documents, wallets, beneficiaries, FX rates, fee bands, transactions, a double-entry ledger and an audit log, with foreign keys and CHECK constraints that reject inconsistent data.
- **Double-entry ledger:** each currency nets to zero across all wallets, which gives a one-query integrity check.
- **Stored procedures** for deposit, transfer, remittance send and completion/refund. Each owns its transaction, is idempotent on a client key, and locks wallets in a global order so concurrent transfers can't deadlock. [A concurrency test](scripts/concurrency_test.py) proves it, and shows deadlocks with a naive version.
- **Triggers** write JSON before/after images to an append-only audit log, mask national IDs, and make transactions and ledger lines immutable.
- **A 10-million-transaction dataset** simulated in time order, with growth, salary-week and Eid peaks, failures and refunds. Every wallet reconciles to its ledger.
- **A tested API:** `make test` runs 46 assertions against the procedures and triggers.

## Quickstart

Requirements: Docker (Docker Desktop, or [Colima](https://github.com/abiosoft/colima) on a Mac without admin rights) with 4 GB+ memory, Python 3.9+, about 15 GB free disk for the full dataset.

```bash
make up                 # MySQL 8.4 in Docker; creates .env with a random root password
make test               # build payflow_test and run the procedure/trigger tests

make generate           # ~10M transactions -> data/generated/*.csv (about 4–5 min)
make setup              # create schema, bulk-load, apply triggers
make reconcile          # ledger invariants: every check should return nothing
make workload           # time the reporting queries the tuning phase will fix

pip install -r requirements.txt
make concurrency        # 16 threads of transfers, zero deadlocks expected
```

For quick iteration, run `make generate-small` (200k transactions, a few seconds) and `make setup DATA_DIR=data/generated-small`.

Phase 2 labs (each uses the small dataset; run one at a time):

```bash
make down                                   # free the standalone server's memory
make repl-up repl-setup repl-status         # classic replication
make repl-promote TARGET=replica1           # manual failover
make repl-down
make cluster-up cluster-setup               # InnoDB Cluster + Router
make failover-demo                          # kill the primary under load and measure
make cluster-down
```

`make help` lists every target.

## Layout

```
schema/
  01_tables.sql          tables, keys, constraints
  02_procedures.sql      money-movement API
  03_triggers.sql        audit trail and immutability (applied after bulk load)
  tests/                 SQL assertions run by `make test`
  queries/               reconciliation checks, reporting workload
docker/standalone/       Phase 1 single-server Compose file and my.cnf
docker/replication/      primary + 2 replicas: setup, status/checksums, promote (manual failover)
docker/cluster/          InnoDB Cluster: AdminAPI setup, Router, failover demo and write probe
scripts/
  generate_data.py       dataset simulator (stdlib only)
  load_data.sh           LOAD DATA INFILE bulk loader
  concurrency_test.py    locking / deadlock demonstration
  ensure_env.sh          creates .env / adds missing random passwords
  lib/common.sh          shared helpers for the docker/* scripts
docs/                    design notes per phase; runbooks and RCAs to come
```

Later phases add `backup/`, `monitoring/`, `security/`, `migration/` and `terraform/`.
