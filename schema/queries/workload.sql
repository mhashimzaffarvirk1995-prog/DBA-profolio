-- =============================================================================
-- Reporting and app queries the performance-tuning phase will optimise.
--
-- Phase 1 shipped only PK / unique / FK indexes on purpose, so several of
-- these were slow on 10M transactions. Phase 4 captured them with the slow
-- query log, ranked them with pt-query-digest and fixed them (indexes in
-- tuning/01_indexes.sql, the Q2 rewrite below); see docs/04-performance-tuning.md.
--
-- Dates are fixed to the end of the generated window so runs are comparable.
-- `make workload` prints each statement with its timing.
-- =============================================================================

SET @as_of = '2026-09-30 00:00:00';

-- Setup, not part of the workload: a busy customer wallet and its owner.
SELECT source_wallet_id INTO @busy_wallet
  FROM transactions
 WHERE txn_id BETWEEN 1 AND 200000 AND txn_type = 'remittance'
 GROUP BY source_wallet_id
 ORDER BY COUNT(*) DESC
 LIMIT 1;
SELECT customer_id INTO @busy_customer FROM wallets WHERE wallet_id = @busy_wallet;
SELECT @busy_wallet, @busy_customer;

-- Q1. Monthly statement for one wallet (customer-facing, must be fast).
CALL sp_wallet_statement(@busy_wallet, '2026-08-01', '2026-09-01');

-- Q2. "Recent activity" screen: last 20 transactions touching a customer.
-- Rewritten in Phase 4: the original OR across source/dest wallet columns
-- could not use either index and scanned 10M rows (19.6 s):
--   WHERE t.source_wallet_id IN (...) OR t.dest_wallet_id IN (...)
-- As UNION ALL each branch uses its own (wallet, created_at) index: 8 ms.
SELECT txn_ref, txn_type, status, amount, currency_code, created_at FROM (
    (SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at
       FROM wallets w JOIN transactions t ON t.source_wallet_id = w.wallet_id
      WHERE w.customer_id = @busy_customer ORDER BY t.created_at DESC LIMIT 20)
    UNION ALL
    (SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at
       FROM wallets w JOIN transactions t ON t.dest_wallet_id = w.wallet_id
      WHERE w.customer_id = @busy_customer ORDER BY t.created_at DESC LIMIT 20)
) recent
ORDER BY created_at DESC
LIMIT 20;

-- Q3. Daily corridor volume, last 30 days (ops dashboard).
SELECT DATE(t.created_at) AS day, t.currency_code, t.payout_currency_code,
       COUNT(*) AS remittances, SUM(t.amount) AS sent, SUM(t.fee_amount) AS fees
  FROM transactions t
 WHERE t.txn_type = 'remittance'
   AND t.created_at >= @as_of - INTERVAL 30 DAY
 GROUP BY DATE(t.created_at), t.currency_code, t.payout_currency_code
 ORDER BY day, t.currency_code;

-- Q4. AML monitoring: customers sending more than 10,000 (send currency) in 30 days.
SELECT w.customer_id, t.currency_code, COUNT(*) AS sends, SUM(t.amount) AS total_sent
  FROM transactions t
  JOIN wallets w ON w.wallet_id = t.source_wallet_id
 WHERE t.txn_type = 'remittance'
   AND t.status <> 'failed'
   AND t.created_at >= @as_of - INTERVAL 30 DAY
 GROUP BY w.customer_id, t.currency_code
HAVING SUM(t.amount) > 10000
 ORDER BY total_sent DESC;

-- Q5. Stuck remittances: pending for more than 24 hours (alerting).
SELECT t.txn_id, t.txn_ref, t.amount, t.currency_code, t.created_at
  FROM transactions t
 WHERE t.status = 'pending'
   AND t.txn_type = 'remittance'
   AND t.created_at < @as_of - INTERVAL 1 DAY
 ORDER BY t.created_at;

-- Q6. Compliance: customers with an expired ID document who sent money in the last 30 days.
SELECT c.customer_id, c.customer_ref, k.doc_type, k.expiry_date
  FROM kyc_documents k
  JOIN customers c ON c.customer_id = k.customer_id
 WHERE k.status = 'expired'
   AND EXISTS (SELECT 1
                 FROM wallets w
                 JOIN transactions t ON t.source_wallet_id = w.wallet_id
                WHERE w.customer_id = c.customer_id
                  AND t.txn_type = 'remittance'
                  AND t.created_at >= @as_of - INTERVAL 30 DAY);

-- Q7. Monthly fee revenue by currency (finance).
SELECT DATE_FORMAT(le.created_at, '%Y-%m') AS month, w.currency_code,
       SUM(IF(le.entry_type = 'credit', le.amount, -le.amount)) AS fee_revenue
  FROM ledger_entries le
  JOIN wallets w ON w.wallet_id = le.wallet_id
 WHERE w.wallet_type = 'fee_revenue'
 GROUP BY month, w.currency_code
 ORDER BY month, w.currency_code;

-- Q8. Look-up by customer reference (control: already indexed, should be ~instant).
SELECT txn_ref INTO @some_ref FROM transactions WHERE txn_id = (SELECT MAX(txn_id) DIV 2 FROM transactions);
SELECT * FROM transactions WHERE txn_ref = @some_ref;
