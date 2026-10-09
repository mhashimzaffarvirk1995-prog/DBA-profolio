#!/usr/bin/env python3
"""
Mixed production workload for the performance-tuning phase.

Three kinds of client run at once for --duration seconds:

  app      (--app threads)      money movement through the stored procedures:
                                deposits, transfers, remittances
  screens  (--screens threads)  customer-facing reads: monthly statement (Q1)
                                and the "recent activity" list (Q2)
  reports  (--reports threads)  ops/finance reports Q3-Q7 from
                                schema/queries/workload.sql, round-robin

Prints, and with --out saves as JSON, throughput and latency percentiles per
operation. Run once before tuning and once after, with the same arguments.

    .venv/bin/python scripts/loadgen.py --duration 180 --out docs/evidence/load-before.json
    .venv/bin/python scripts/loadgen.py --q2 rewrite --out docs/evidence/load-after.json
"""

import argparse
import json
import os
import random
import statistics
import sys
import threading
import time
import uuid
from decimal import Decimal

import mysql.connector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AS_OF = "2026-09-30 00:00:00"

# Q2 as first written, and as rewritten in the tuning phase: OR across two
# columns becomes UNION ALL so each branch can use its own index.
Q2 = {
    "original": """
        SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at
          FROM transactions t
         WHERE t.source_wallet_id IN (SELECT wallet_id FROM wallets WHERE customer_id = %(c)s)
            OR t.dest_wallet_id   IN (SELECT wallet_id FROM wallets WHERE customer_id = %(c)s)
         ORDER BY t.created_at DESC
         LIMIT 20""",
    "rewrite": """
        SELECT txn_ref, txn_type, status, amount, currency_code, created_at FROM (
            (SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at
               FROM wallets w JOIN transactions t ON t.source_wallet_id = w.wallet_id
              WHERE w.customer_id = %(c)s ORDER BY t.created_at DESC LIMIT 20)
            UNION ALL
            (SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at
               FROM wallets w JOIN transactions t ON t.dest_wallet_id = w.wallet_id
              WHERE w.customer_id = %(c)s ORDER BY t.created_at DESC LIMIT 20)
        ) recent
        ORDER BY created_at DESC
        LIMIT 20""",
}

REPORTS = {
    "Q3 corridor volume": f"""
        SELECT DATE(t.created_at) AS day, t.currency_code, t.payout_currency_code,
               COUNT(*), SUM(t.amount), SUM(t.fee_amount)
          FROM transactions t
         WHERE t.txn_type = 'remittance' AND t.created_at >= '{AS_OF}' - INTERVAL 30 DAY
         GROUP BY DATE(t.created_at), t.currency_code, t.payout_currency_code""",
    "Q4 AML 30-day": f"""
        SELECT w.customer_id, t.currency_code, COUNT(*), SUM(t.amount) AS total_sent
          FROM transactions t JOIN wallets w ON w.wallet_id = t.source_wallet_id
         WHERE t.txn_type = 'remittance' AND t.status <> 'failed'
           AND t.created_at >= '{AS_OF}' - INTERVAL 30 DAY
         GROUP BY w.customer_id, t.currency_code
        HAVING SUM(t.amount) > 10000""",
    "Q5 stuck remittances": f"""
        SELECT t.txn_id, t.txn_ref, t.amount, t.currency_code, t.created_at
          FROM transactions t
         WHERE t.status = 'pending' AND t.txn_type = 'remittance'
           AND t.created_at < '{AS_OF}' - INTERVAL 1 DAY
         ORDER BY t.created_at""",
    "Q6 expired KYC": f"""
        SELECT c.customer_id, c.customer_ref, k.doc_type, k.expiry_date
          FROM kyc_documents k JOIN customers c ON c.customer_id = k.customer_id
         WHERE k.status = 'expired'
           AND EXISTS (SELECT 1 FROM wallets w JOIN transactions t ON t.source_wallet_id = w.wallet_id
                        WHERE w.customer_id = c.customer_id AND t.txn_type = 'remittance'
                          AND t.created_at >= '{AS_OF}' - INTERVAL 30 DAY)""",
    "Q7 fee revenue": """
        SELECT DATE_FORMAT(le.created_at, '%Y-%m') AS month, w.currency_code,
               SUM(IF(le.entry_type = 'credit', le.amount, -le.amount))
          FROM ledger_entries le JOIN wallets w ON w.wallet_id = le.wallet_id
         WHERE w.wallet_type = 'fee_revenue'
         GROUP BY month, w.currency_code""",
}


def read_env():
    env = {}
    path = os.path.join(ROOT, ".env")
    if os.path.exists(path):
        for line in open(path):
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                env[k] = v.split("#")[0].strip()
    return env


# Reads get a time budget, as a real reporting SLA would; a query that hits it
# is counted as a timeout instead of stalling the test.
READ_TIMEOUT_MS = 120_000


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.ops = {}

    def add(self, op, seconds, outcome):
        with self.lock:
            s = self.ops.setdefault(op, {"lat": [], "errors": 0, "timeouts": 0})
            if outcome == "ok":
                s["lat"].append(seconds)
            elif outcome == "timeout":
                s["timeouts"] += 1
            else:
                s["errors"] += 1

    def summary(self, duration):
        out = {}
        for op, s in sorted(self.ops.items()):
            lat = sorted(s["lat"])
            n = len(lat)
            pct = lambda p: round(lat[min(n - 1, int(n * p))] * 1000, 1) if n else None
            out[op] = {"count": n, "errors": s["errors"], "timeouts": s["timeouts"], "per_sec": round(n / duration, 1),
                       "p50_ms": pct(0.50), "p95_ms": pct(0.95), "p99_ms": pct(0.99),
                       "max_ms": round(lat[-1] * 1000, 1) if n else None}
        return out


def connect(args):
    return mysql.connector.connect(host=args.host, port=args.port, user=args.user, password=args.password,
                                   database="payflow", autocommit=True, ssl_ca=os.path.join(ROOT, ".private/tls/ca.pem"),
                                   ssl_verify_cert=True, ssl_verify_identity=True)


def timed(stats, op, fn):
    t0 = time.perf_counter()
    try:
        fn()
        stats.add(op, time.perf_counter() - t0, "ok")
    except mysql.connector.Error as e:
        if e.errno == 3024:                       # ER_QUERY_TIMEOUT (max_execution_time)
            stats.add(op, time.perf_counter() - t0, "timeout")
        else:
            # Business-rule refusals (e.g. insufficient funds) are normal outcomes.
            stats.add(op, time.perf_counter() - t0, "ok" if e.sqlstate == "45000" else "error")


def app_worker(args, sample, stats, stop, seed):
    rng = random.Random(seed)
    conn = connect(args)
    cur = conn.cursor()
    by_ccy = {}
    for row in sample:
        by_ccy.setdefault(row["ccy"], []).append(row)
    key = lambda: f"load-{uuid.uuid4().hex}"
    while not stop.is_set():
        r = rng.random()
        a = rng.choice(sample)
        if r < 0.4:
            amt = Decimal(rng.randrange(2000, 50000)) / 100
            timed(stats, "app deposit", lambda: cur.callproc("sp_deposit", (a["wallet"], amt, "app", key(), 0)))
        elif r < 0.6:
            b = rng.choice(by_ccy[a["ccy"]])
            if b["wallet"] == a["wallet"]:
                continue
            amt = Decimal(rng.randrange(500, 5000)) / 100
            timed(stats, "app transfer",
                  lambda: cur.callproc("sp_transfer_funds", (a["wallet"], b["wallet"], amt, "app", key(), 0)))
        else:
            amt = Decimal(rng.randrange(2000, 30000)) / 100
            timed(stats, "app remittance",
                  lambda: cur.callproc("sp_send_remittance", (a["wallet"], a["ben"], amt, "app", key(), 0)))
    conn.close()


def screen_worker(args, sample, stats, stop, seed):
    rng = random.Random(seed)
    conn = connect(args)
    cur = conn.cursor()
    cur.execute(f"SET SESSION max_execution_time = {READ_TIMEOUT_MS}")
    q2 = Q2[args.q2]

    def statement(w):
        cur.callproc("sp_wallet_statement", (w, "2026-08-01", "2026-09-01"))
        for res in cur.stored_results():
            res.fetchall()

    def recent(c):
        cur.execute(q2, {"c": c})
        cur.fetchall()

    while not stop.is_set():
        a = rng.choice(sample)
        if rng.random() < 0.5:
            timed(stats, "Q1 statement", lambda: statement(a["wallet"]))
        else:
            timed(stats, "Q2 recent activity", lambda: recent(a["customer"]))
    conn.close()


def report_worker(args, stats, stop, seed):
    conn = connect(args)
    cur = conn.cursor()
    cur.execute(f"SET SESSION max_execution_time = {READ_TIMEOUT_MS}")
    names = list(REPORTS)
    random.Random(seed).shuffle(names)
    i = 0
    while not stop.is_set():
        name = names[i % len(names)]
        i += 1

        def run():
            cur.execute(REPORTS[name])
            cur.fetchall()
        timed(stats, name, run)
    conn.close()


def main():
    env = read_env()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=3306)
    p.add_argument("--user", default="payflow_bench" if os.path.exists(os.path.join(ROOT, ".private/security-enabled")) else "root")
    p.add_argument("--password", default=env.get("BENCH_PASSWORD" if os.path.exists(os.path.join(ROOT, ".private/security-enabled")) else "MYSQL_ROOT_PASSWORD", ""))
    p.add_argument("--duration", type=int, default=180)
    p.add_argument("--app", type=int, default=8)
    p.add_argument("--screens", type=int, default=4)
    p.add_argument("--reports", type=int, default=2)
    p.add_argument("--q2", choices=sorted(Q2), default="original")
    p.add_argument("--label", default="")
    p.add_argument("--out", help="write results as JSON here")
    args = p.parse_args()

    conn = connect(args)
    cur = conn.cursor(dictionary=True)
    # Active, KYC-verified customers with a beneficiary: they can do everything.
    cur.execute("""
        SELECT w.wallet_id AS wallet, w.customer_id AS customer, w.currency_code AS ccy,
               MIN(b.beneficiary_id) AS ben
          FROM wallets w
          JOIN customers c ON c.customer_id = w.customer_id
          JOIN beneficiaries b ON b.customer_id = w.customer_id AND b.is_active
         WHERE w.wallet_type = 'customer' AND c.status = 'active' AND c.kyc_status = 'verified'
           AND w.wallet_id % 50 = 7
         GROUP BY w.wallet_id, w.customer_id, w.currency_code
         LIMIT 3000""")
    sample = cur.fetchall()
    conn.close()

    stats, stop = Stats(), threading.Event()
    threads = [threading.Thread(target=app_worker, args=(args, sample, stats, stop, i)) for i in range(args.app)]
    threads += [threading.Thread(target=screen_worker, args=(args, sample, stats, stop, 100 + i))
                for i in range(args.screens)]
    threads += [threading.Thread(target=report_worker, args=(args, stats, stop, 200 + i))
                for i in range(args.reports)]
    print(f"{args.app} app + {args.screens} screen + {args.reports} report threads for {args.duration}s "
          f"(Q2 {args.q2}), {len(sample)} sample wallets", file=sys.stderr)
    t0 = time.time()
    for t in threads:
        t.start()
    time.sleep(args.duration)
    stop.set()
    for t in threads:
        t.join()
    elapsed = time.time() - t0

    summary = stats.summary(elapsed)
    print(f"\n{'operation':<22}{'count':>8}{'errors':>8}{'timeout':>8}{'per_sec':>9}{'p50_ms':>10}{'p95_ms':>10}{'p99_ms':>10}{'max_ms':>10}")
    for op, s in summary.items():
        print(f"{op:<22}{s['count']:>8}{s['errors']:>8}{s['timeouts']:>8}{s['per_sec']:>9}"
              f"{str(s['p50_ms']):>10}{str(s['p95_ms']):>10}{str(s['p99_ms']):>10}{str(s['max_ms']):>10}")
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"label": args.label, "duration_s": round(elapsed), "q2": args.q2,
                       "threads": {"app": args.app, "screens": args.screens, "reports": args.reports},
                       "results": summary}, f, indent=2)
        print(f"\nsaved {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
