-- =============================================================================
-- Ledger reconciliation: the checks a finance/ops team runs every night.
-- Every query should return zero rows / zero counts. `make reconcile`.
-- On the full dataset the GROUP BYs over ledger_entries scan ~25M rows and
-- take minutes; that is expected.
-- =============================================================================

SELECT '1. per-currency balance (double entry => must be 0)' AS check_name;
SELECT currency_code, SUM(balance) AS net_balance
  FROM wallets
 GROUP BY currency_code
HAVING SUM(balance) <> 0;

SELECT '2. customer wallets below zero' AS check_name;
SELECT COUNT(*) AS negative_wallets
  FROM wallets
 WHERE wallet_type = 'customer' AND balance < 0;

SELECT '3. wallets whose cached balance differs from their ledger' AS check_name;
SELECT w.wallet_id, w.balance, COALESCE(l.net, 0) AS ledger_net
  FROM wallets w
  LEFT JOIN (SELECT wallet_id, SUM(IF(entry_type = 'credit', amount, -amount)) AS net
               FROM ledger_entries
              GROUP BY wallet_id) l ON l.wallet_id = w.wallet_id
 WHERE w.balance <> COALESCE(l.net, 0)
 LIMIT 20;

SELECT '4. transactions whose debits and credits differ' AS check_name;
SELECT txn_id,
       SUM(IF(entry_type = 'debit',  amount, 0)) AS debits,
       SUM(IF(entry_type = 'credit', amount, 0)) AS credits
  FROM ledger_entries
 GROUP BY txn_id
HAVING debits <> credits
 LIMIT 20;

SELECT '5. money-moving transactions with no ledger lines' AS check_name;
SELECT t.txn_type, t.status, COUNT(*) AS missing
  FROM transactions t
 WHERE (t.status = 'completed' OR t.txn_type = 'remittance')
   AND NOT EXISTS (SELECT 1 FROM ledger_entries le WHERE le.txn_id = t.txn_id)
 GROUP BY t.txn_type, t.status;

SELECT '6. failed remittances that were never refunded' AS check_name;
SELECT COUNT(*) AS unrefunded
  FROM transactions t
 WHERE t.txn_type = 'remittance' AND t.status = 'failed'
   AND NOT EXISTS (SELECT 1 FROM transactions r WHERE r.reversal_of_txn_id = t.txn_id);
