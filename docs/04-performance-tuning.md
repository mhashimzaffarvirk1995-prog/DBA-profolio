# Phase 4: Performance tuning

Phase 1 left the schema with only the indexes correctness needed, on purpose, so this phase could tune from evidence rather than guesswork. The method:

1. **Measure** a realistic mixed workload with the slow query log on.
2. **Rank** what costs most with `pt-query-digest`.
3. **Explain** each culprit with `EXPLAIN ANALYZE`.
4. **Fix** with the smallest change that addresses the cause.
5. **Measure again,** identically.

## Headline

| | Before | After | |
|---|---|---|---|
| **"Recent activity" screen (Q2), p50 under load** | **15.7 s** | **6.7 ms** | ~2,350× |
| Monthly statement (Q1), p50 under load | 49.7 ms | 6.7 ms | 7× |
| Fee revenue report (Q7) | **>120 s (timed out)** | 5.6 s | >21× |
| Stuck-remittance alert query (Q5) | 15.5 s | 0.34 s | 45× |
| Customer screens served | 0.5 / s | **449 / s** | |
| Payments (deposits, transfers, remittances) | 307 / s, slowest 1,084 ms | **314 / s, slowest 308 ms** | no regression |
| Time spent in slow queries (180 s run) | ~1,990 s | ~412 s | while doing ~900× more reads |

## 1. The workload

[scripts/loadgen.py](../scripts/loadgen.py) runs three kinds of client at once for 180 s, after a 60 s warm-up:

| Clients | Threads | Does |
|---|---|---|
| app | 8 | `sp_deposit`, `sp_transfer_funds`, `sp_send_remittance` on 3,000 real KYC-verified wallets |
| screens | 4 | Q1 monthly statement, Q2 recent activity |
| reports | 2 | Q3–Q7 from [workload.sql](../schema/queries/workload.sql), round-robin |

Reads get a **120 s budget** (`max_execution_time`), as a reporting SLA would. The first attempt had none, and two copies of Q7 ran for 23 minutes and stalled the test.

[tuning/perf-run.sh](../tuning/perf-run.sh) wraps one measured run in four steps: warm-up, slow log on (`long_query_time = 0.1`, `log_slow_extra`), the load, then `pt-query-digest`. Every run's numbers and reports are in [docs/evidence/phase4/](evidence/phase4/). It runs under `caffeinate`, because a laptop that slept mid-run paused the Docker VM and produced a 17-minute gap and meaningless numbers. That run was discarded and repeated.

## 2. Where the time went (before)

`pt-query-digest` on the baseline slow log ([before-digest.txt](evidence/phase4/before-digest.txt)):

| Rank | Query | Share of response time | Per call |
|---|---|---|---|
| 1 | **Q2 recent activity** | **56.1 %** | 15.1 s |
| 2 | **Q7 fee revenue** | **23.6 %** | 117 s |
| 3 | Q6 expired KYC | 6.2 % | 15.3 s |
| 4–5 | `sp_send_remittance`, `sp_deposit` slow tail | 9.2 % | 0.17 s |
| 6–8 | Q4 AML, Q3 corridor, Q5 stuck remittances | 4.7 % | 14–18 s |

Two queries took 80 % of the server's time. The payment procedures were only slow because the scans were evicting their pages from the buffer pool.

## 3. Diagnosis and fixes

`EXPLAIN ANALYZE` (actual rows and time per plan step; [before](evidence/phase4/before-explain.txt), [after](evidence/phase4/after-tuning-explain.txt)), on an idle server:

| Query | Cause (before) | Fix | Before | After |
|---|---|---|---|---|
| **Q2** recent activity | `WHERE source_wallet_id IN (…) OR dest_wallet_id IN (…)`: an `OR` across two columns can't use either index, so it **scanned all 10M rows** | **Rewrite as `UNION ALL`** of two branches, each with its own `(wallet_id, created_at)` index | 19,596 ms | **5.4 ms** |
| **Q7** fee revenue | full scan of 22.7M ledger lines plus a wallet lookup per line | covering index `ledger_entries (wallet_id, created_at, entry_type, amount)`: reads only the fee wallets' lines, from the index alone | 42,130 ms | 4,833 ms |
| Q1 statement | FK index on `wallet_id` only; date filter applied row by row | same `(wallet_id, created_at, …)` index → range scan | 104 ms | 3.1 ms |
| Q3 corridor volume | full scan for 30 days of one type | `transactions (txn_type, created_at)` | 8,276 ms | 621 ms |
| Q4 AML 30-day | same | same index | 6,941 ms | 1,373 ms |
| Q5 stuck remittances | full scan for a 0.1 % slice | `transactions (status, txn_type, created_at)` | 7,875 ms | 205 ms |
| Q6 expired KYC | full scan of KYC + per-customer transaction scans | `kyc_documents (status, customer_id)` + `transactions (source_wallet_id, created_at)` for the `EXISTS` | 15,585 ms | 2,829 ms |

**The biggest win needed no index at all.** The `UNION ALL` rewrite of Q2 ran in 10 ms using only the Phase 1 foreign-key indexes. The `OR` was the problem, not missing indexes.

**Applying them:** [tuning/01_indexes.sql](../tuning/01_indexes.sql) uses online DDL (`ALGORITHM=INPLACE, LOCK=NONE`), so payments keep flowing while it runs.

| Table | Build time |
|---|---|
| `transactions`, 4 indexes on 10M rows | 47.5 s |
| `ledger_entries`, 1 covering index on 22.7M rows | 45.8 s |
| `kyc_documents` | 0.6 s |

MySQL dropped the three implicit foreign-key indexes on its own, because each new index begins with the same column. `pt-duplicate-key-checker` then found **no redundant indexes** ([duplicate-keys.txt](evidence/phase4/duplicate-keys.txt)).

**What's left is real work, not waste.** Q4 aggregates 327k remittances from the last 30 days, and Q7 sums every fee line in two years. If these must be sub-second, the next step is a summary table maintained by the application (daily corridor totals, monthly fee totals), not more indexes.

## 4. Server configuration

| Setting | Before | After | Why |
|---|---|---|---|
| `innodb_buffer_pool_size` | 1 GB | **2 GB** | The hot working set (last 90 days of transactions + ledger) is **1.3 GB** now and **2.0 GB** in 12 months (capacity plan below). With 1 GB, reports evicted the pages payments needed. Resized **online in 1 s** (`SET GLOBAL`, no restart), then persisted in [my.cnf](../docker/standalone/my.cnf). |
| `innodb_io_capacity`, `innodb_log_buffer_size`, change buffering | 8.4 defaults | unchanged | MySQL 8.4 already ships SSD-era defaults (`io_capacity=10000`, change buffering off). Changing them without evidence would be guesswork. |

The effect shows in the two "after" runs:

| p50 under load | Indexes only, 1 GB pool | + 2 GB pool |
|---|---|---|
| Q2 recent activity | 18 ms | 6.7 ms |
| Q5 stuck remittances | 4.3 s | 0.34 s |
| Q7 fee revenue | 12.3 s | 5.6 s |
| slowest payment (max) | 2.8 s | 0.31 s |

**Lab caveat:** with a 2 GB pool, mysqld uses ~2.9 GB of the 4 GB Docker VM. A dedicated production host would size the pool at ~70 % of RAM and leave the rest for connections, sort buffers and the OS. For this data that's a 4 GB pool on a 6–8 GB server, which also covers the 24-month working set.

## 5. The cost of the indexes

Indexes make every write do more work, so payments were measured in every run:

| Payments | Before | Indexes, 1 GB | + 2 GB pool |
|---|---|---|---|
| Throughput | 307 / s | 288 / s | **314 / s** |
| p95 latency (remittance) | 76.5 ms | 79.7 ms | **59.4 ms** |
| max latency | 1,084 ms | 2,830 ms | **308 ms** |

With the smaller pool, the five new indexes cost about 6 % of write throughput, partly because screens were now doing 180 reads per second instead of waiting. With the right-sized pool, payments ended up slightly faster than before, and their worst case improved 3.5×.

## 6. Capacity plan

From [tuning/capacity.py](../tuning/capacity.py) ([output](evidence/phase4/capacity.md)), using measured bytes per row (849 B per transaction including its ledger lines and all indexes) and a linear trend over the last 12 full months:

| Horizon | Transactions / month | Database size | Hot working set → buffer pool |
|---|---|---|---|
| now | 584k | 8.4 GB | 1.3 GB → 2 GB pool |
| +12 months | 854k | 15.4 GB | 2.0 GB → 3 GB pool |
| +24 months | 1.1M | 24.8 GB | 2.6 GB → 4 GB pool |

The original capacity model included binlogs (7 days), two full backups, three dumps and the binlog archive on top, so the data and backup volumes should be budgeted at roughly **3× the database size**: about 75 GB at 24 months. Revisit the pool size when the 90-day working set passes ~70 % of it, which the monitoring in Phase 5 makes visible as the buffer pool hit rate.

## Current operating settings

The tables above describe the measured Phase 4 tuning run. The current 3.8 GB
Docker VM uses a persisted 768 MB buffer pool to leave room for monitoring, RAM
staging and independent recovery; the dedicated-host configuration remains 2 GB.
Current retention is one verified encrypted full and two encrypted logical dumps.
Recalculate disk headroom for encrypted staging and recovery rather than treating
the historical 3× estimate as a hard limit.

After Phase 6 setup, host load/concurrency/capacity clients use `payflow_bench`
with the private lab CA and server identity verification. Direct test writes are
limited to `payflow_test`; statistics refresh runs through the local administrator
socket in `make capacity`. Slow logging is normally off. Protect and retire any
new raw slow logs after a tuning run as described in [Phase 6](06-security-compliance.md).

## Reproduce

```bash
make up ops-up                                       # server + ops image (pt-query-digest)
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
make perf-run LABEL=before                           # baseline
make explain LABEL=before
make tuning-apply                                    # online indexes
make perf-run LABEL=after ARGS="--q2 rewrite"
make capacity
```
