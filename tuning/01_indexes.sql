-- =============================================================================
-- Phase 4 index changes, chosen from the pt-query-digest ranking and
-- EXPLAIN ANALYZE of the baseline run (see docs/04-performance-tuning.md).
--
-- All are online DDL (ALGORITHM=INPLACE, LOCK=NONE): payments keep flowing
-- while the indexes build. The indexes InnoDB created implicitly for the
-- foreign keys on source_wallet_id, dest_wallet_id and ledger wallet_id are
-- dropped by MySQL itself once a new index can enforce the same key;
-- pt-duplicate-key-checker afterwards reported no duplicates.
-- =============================================================================

-- Q2 recent activity (after the UNION ALL rewrite), Q4/Q6 joins from wallets,
-- and the per-wallet history behind them: wallet first, newest first.
ALTER TABLE transactions
    ADD INDEX idx_txn_source_created (source_wallet_id, created_at),
    ADD INDEX idx_txn_dest_created   (dest_wallet_id, created_at),
-- Q3 corridor volume and Q4 AML: one transaction type over a date range.
    ADD INDEX idx_txn_type_created   (txn_type, created_at),
-- Q5 stuck remittances: a tiny slice (status = pending) that was a full scan.
    ADD INDEX idx_txn_status_type_created (status, txn_type, created_at),
    ALGORITHM = INPLACE, LOCK = NONE;

-- Q1 statements and Q7 fee revenue: a wallet's ledger lines by date. entry_type
-- and amount are included so Q7 is answered from the index alone (covering),
-- without 3M primary-key lookups.
ALTER TABLE ledger_entries
    ADD INDEX idx_ledger_wallet_created (wallet_id, created_at, entry_type, amount),
    ALGORITHM = INPLACE, LOCK = NONE;

-- Q6 compliance: expired documents first, then their customers.
ALTER TABLE kyc_documents
    ADD INDEX idx_kyc_status_customer (status, customer_id),
    ALGORITHM = INPLACE, LOCK = NONE;
