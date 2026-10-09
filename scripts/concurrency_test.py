#!/usr/bin/env python3
"""
Concurrency test for sp_transfer_funds.

Many threads fire random transfers, in both directions, between a small set
of wallets so that the same rows are fought over constantly. Afterwards the
script checks that no money was created or lost:

  * the test wallets still hold exactly what was deposited, in total
  * no customer wallet is negative
  * every wallet balance equals its ledger total

and reports deadlocks. sp_transfer_funds locks wallets in ascending id order,
so it should report zero. Run with --naive to compare against a version that
locks "from" then "to"; that one deadlocks under the same load.

    pip install -r requirements.txt
    make test            # builds payflow_test with fixtures
    make concurrency     # or: python3 scripts/concurrency_test.py --naive
"""

import argparse
import os
import random
import statistics
import sys
import threading
import time
import uuid
from decimal import Decimal

try:
    import mysql.connector
    from mysql.connector import errorcode
except ImportError:
    sys.exit("mysql-connector-python is required: pip install -r requirements.txt")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NAIVE_PROC = """
CREATE PROCEDURE demo_transfer_naive(
    IN p_from BIGINT UNSIGNED, IN p_to BIGINT UNSIGNED, IN p_amount DECIMAL(19,4),
    IN p_channel VARCHAR(8), IN p_key VARCHAR(64), OUT p_txn_id BIGINT UNSIGNED)
BEGIN
    -- Same as sp_transfer_funds but locks in argument order: A->B and B->A
    -- running together each hold one lock and wait for the other.
    DECLARE v_balance DECIMAL(19,4);
    DECLARE v_now DATETIME(6) DEFAULT UTC_TIMESTAMP(6);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    START TRANSACTION;
    SELECT balance INTO v_balance FROM wallets WHERE wallet_id = p_from FOR UPDATE;
    SELECT wallet_id INTO p_txn_id FROM wallets WHERE wallet_id = p_to FOR UPDATE;
    IF v_balance < p_amount THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;
    INSERT INTO transactions (txn_ref, idempotency_key, txn_type, status, channel, source_wallet_id,
                              dest_wallet_id, amount, currency_code, created_at, completed_at)
    VALUES (CONCAT('PF', DATE_FORMAT(v_now, '%y%m%d'), HEX(RANDOM_BYTES(5))), p_key, 'transfer', 'completed',
            p_channel, p_from, p_to, p_amount, 'GBP', v_now, v_now);
    SET p_txn_id = LAST_INSERT_ID();
    CALL sp_post_entry(p_txn_id, p_from, 'debit', p_amount, v_now);
    CALL sp_post_entry(p_txn_id, p_to, 'credit', p_amount, v_now);
    COMMIT;
END
"""


def read_env():
    env = {}
    path = os.path.join(ROOT, ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    return env


def connect(args):
    where = {"unix_socket": args.socket} if args.socket else {"host": args.host, "port": args.port}
    return mysql.connector.connect(user=args.user, password=args.password, database=args.database,
                                   autocommit=True, ssl_ca=os.path.join(ROOT, ".private/tls/ca.pem"),
                                   ssl_verify_cert=True, ssl_verify_identity=True, **where)


def setup(args):
    """Create fresh customers with one funded GBP wallet each; return wallet ids."""
    conn = connect(args)
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM wallets w JOIN customers c USING (customer_id) "
                "WHERE c.customer_ref = 'PAYFLOW-HOUSE' AND w.currency_code = 'GBP'")
    if cur.fetchone()[0] == 0:
        sys.exit(f"No GBP house wallets in {args.database}. Run `make test` first to build it.")

    if args.naive:
        cur.execute("DROP PROCEDURE IF EXISTS demo_transfer_naive")
        cur.execute(NAIVE_PROC)

    run = uuid.uuid4().hex[:8]
    wallets = []
    for i in range(args.wallets):
        cur.execute(
            "INSERT INTO customers (customer_ref, first_name, last_name, email, phone, "
            "nationality_country_code, residence_country_code, kyc_status) "
            "VALUES (%s, 'Load', %s, %s, '+440', 'GB', 'GB', 'verified')",
            (f"CONC-{run}-{i}", f"Test{i}", f"load.{run}.{i}@example.com"))
        cur.execute("INSERT INTO wallets (customer_id, currency_code) VALUES (%s, 'GBP')", (cur.lastrowid,))
        wid = cur.lastrowid
        cur.callproc("sp_deposit", (wid, Decimal(args.deposit), "api", f"conc-{run}-dep-{i}", 0))
        wallets.append(wid)
    conn.close()
    return run, wallets


def worker(args, run, wallets, n_ops, stats, lock, thread_no):
    proc = "demo_transfer_naive" if args.naive else "sp_transfer_funds"
    rng = random.Random(thread_no)
    conn = connect(args)
    cur = conn.cursor()
    local = {"ok": 0, "insufficient": 0, "deadlock": 0, "lock_timeout": 0, "other": 0, "latency": []}
    for op in range(n_ops):
        a, b = rng.sample(wallets, 2)
        amount = Decimal(rng.randrange(100, 5000)) / 100
        t0 = time.perf_counter()
        try:
            cur.callproc(proc, (a, b, amount, "api", f"conc-{run}-{thread_no}-{op}", 0))
            local["ok"] += 1
        except mysql.connector.Error as e:
            if e.errno == errorcode.ER_LOCK_DEADLOCK:
                local["deadlock"] += 1
            elif e.errno == errorcode.ER_LOCK_WAIT_TIMEOUT:
                local["lock_timeout"] += 1
            elif "Insufficient funds" in str(e):
                local["insufficient"] += 1
            else:
                local["other"] += 1
                if local["other"] <= 3:
                    print(f"  thread {thread_no}: {e}", file=sys.stderr)
        local["latency"].append(time.perf_counter() - t0)
    conn.close()
    with lock:
        for k, v in local.items():
            stats[k] = stats.get(k, [] if k == "latency" else 0) + v


def verify(args, wallets, expected_total):
    conn = connect(args)
    cur = conn.cursor()
    ids = ",".join(str(w) for w in wallets)
    cur.execute(f"SELECT SUM(balance), MIN(balance) FROM wallets WHERE wallet_id IN ({ids})")
    total, minimum = cur.fetchone()
    cur.execute(f"""
        SELECT COUNT(*) FROM wallets w
          JOIN (SELECT wallet_id, SUM(IF(entry_type = 'credit', amount, -amount)) AS net
                  FROM ledger_entries WHERE wallet_id IN ({ids}) GROUP BY wallet_id) l
            ON l.wallet_id = w.wallet_id
         WHERE w.balance <> l.net""")
    mismatched = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM (SELECT currency_code FROM wallets GROUP BY currency_code "
                "HAVING SUM(balance) <> 0) x")
    unbalanced_ccy = cur.fetchone()[0]
    conn.close()
    checks = [
        (f"money conserved: {total} == {expected_total}", total == expected_total),
        (f"no negative wallet (min {minimum})", minimum >= 0),
        (f"wallet balances match ledger ({mismatched} mismatched)", mismatched == 0),
        (f"every currency nets to zero ({unbalanced_ccy} unbalanced)", unbalanced_ccy == 0),
    ]
    for label, ok in checks:
        print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    return all(ok for _, ok in checks)


def main():
    env = read_env()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=3306)
    p.add_argument("--socket", help="connect through a Unix socket instead of TCP")
    p.add_argument("--user", default="payflow_bench" if os.path.exists(os.path.join(ROOT, ".private/security-enabled")) else "root")
    p.add_argument("--password", default=env.get("BENCH_PASSWORD" if os.path.exists(os.path.join(ROOT, ".private/security-enabled")) else "MYSQL_ROOT_PASSWORD", ""))
    p.add_argument("--database", default="payflow_test")
    p.add_argument("--threads", type=int, default=16)
    p.add_argument("--ops", type=int, default=300, help="transfers per thread")
    p.add_argument("--wallets", type=int, default=8, help="fewer wallets = more contention")
    p.add_argument("--deposit", default="1000.00", help="starting balance per wallet")
    p.add_argument("--naive", action="store_true", help="use a procedure without ordered locking")
    args = p.parse_args()

    run, wallets = setup(args)
    expected_total = Decimal(args.deposit) * len(wallets)
    mode = "naive (unordered locks)" if args.naive else "sp_transfer_funds (ordered locks)"
    print(f"{mode}: {args.threads} threads x {args.ops} transfers over {len(wallets)} wallets")

    stats, lock = {}, threading.Lock()
    threads = [threading.Thread(target=worker, args=(args, run, wallets, args.ops, stats, lock, i))
               for i in range(args.threads)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - t0

    lat = sorted(stats["latency"])
    total_ops = len(lat)
    print(f"  {total_ops:,} calls in {elapsed:.1f}s ({total_ops / elapsed:,.0f}/s), "
          f"p50 {statistics.median(lat) * 1000:.1f} ms, p95 {lat[int(total_ops * 0.95)] * 1000:.1f} ms")
    print(f"  committed {stats['ok']:,}  insufficient funds {stats['insufficient']:,}  "
          f"deadlocks {stats['deadlock']:,}  lock timeouts {stats['lock_timeout']:,}  other {stats['other']:,}")

    ok = verify(args, wallets, expected_total)
    if not args.naive and stats["deadlock"]:
        print("  FAIL  ordered locking should not deadlock")
        ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
