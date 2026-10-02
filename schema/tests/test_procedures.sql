-- =============================================================================
-- Tests for the stored procedures and triggers.
-- Run by `make test` against a freshly built payflow_test database
-- (tables + procedures + triggers, no generated data).
-- Any failed assertion raises an error and stops the run with a non-zero exit.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tiny assertion helpers
-- -----------------------------------------------------------------------------
DELIMITER $$

DROP PROCEDURE IF EXISTS t_assert$$
CREATE PROCEDURE t_assert(IN p_label VARCHAR(200), IN p_ok BOOLEAN)
BEGIN
    DECLARE v_msg VARCHAR(128);
    IF p_ok IS NULL OR NOT p_ok THEN
        SET v_msg = LEFT(CONCAT('FAIL: ', p_label), 128);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
    SELECT CONCAT('PASS  ', p_label) AS result;
END$$

-- Runs p_sql and passes only if it raises an error whose message contains p_expect.
DROP PROCEDURE IF EXISTS t_expect_error$$
CREATE PROCEDURE t_expect_error(IN p_label VARCHAR(200), IN p_sql TEXT, IN p_expect VARCHAR(200))
BEGIN
    DECLARE v_error TEXT DEFAULT NULL;
    DECLARE v_msg   VARCHAR(128);
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        GET DIAGNOSTICS CONDITION 1 v_error = MESSAGE_TEXT;

    SET @t_sql = p_sql;
    PREPARE t_stmt FROM @t_sql;
    EXECUTE t_stmt;
    DEALLOCATE PREPARE t_stmt;

    IF v_error IS NULL THEN
        SET v_msg = LEFT(CONCAT('FAIL: ', p_label, ' (no error raised)'), 128);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
    IF LOCATE(p_expect, v_error) = 0 THEN
        SET v_msg = LEFT(CONCAT('FAIL: ', p_label, ' (got: ', v_error, ')'), 128);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
    SELECT CONCAT('PASS  ', p_label, '  [', v_error, ']') AS result;
END$$

DELIMITER ;

-- -----------------------------------------------------------------------------
-- Fixtures
--   house account 1: wallets 1/2 = GBP settlement/fee, 3/4 = PKR settlement/fee
--   customer 10 (verified, GB)  wallet 10 GBP, beneficiary 100 in PK
--   customer 11 (verified, GB)  wallet 11 GBP, wallet 12 PKR, beneficiary 101 in PK
--   customer 12 (KYC pending)   wallet 13 GBP
-- -----------------------------------------------------------------------------
SET @app_user = 'test-runner';

INSERT INTO currencies VALUES ('GBP', 'Pound Sterling', 2), ('PKR', 'Pakistani Rupee', 2);
INSERT INTO countries VALUES ('GB', 'United Kingdom', 'GBP', '+44', TRUE, FALSE),
                             ('PK', 'Pakistan',       'PKR', '+92', FALSE, TRUE);
INSERT INTO exchange_rates (base_currency_code, quote_currency_code, mid_rate, customer_rate, source, valid_from)
VALUES ('GBP', 'PKR', 360.00, 355.50, 'TEST', '2020-01-01 00:00:00');
INSERT INTO remittance_fees (currency_code, dest_country_code, min_amount, max_amount, fee_amount)
VALUES ('GBP', 'PK',   0, 100,        1.99),
       ('GBP', 'PK', 100, 500,        0.99),
       ('GBP', 'PK', 500, 1000000000, 0.00);

INSERT INTO customers (customer_id, customer_ref, customer_type, first_name, last_name, email, phone,
                       nationality_country_code, residence_country_code, national_id_number, kyc_status)
VALUES (1,  'PAYFLOW-HOUSE', 'system',     'PayFlow', 'House', 'house@payflow.example', '+440', 'GB', 'GB', NULL, 'verified'),
       (10, 'CUS-T10',       'individual', 'Ayesha',  'Khan',  'ayesha@example.com',    '+441', 'PK', 'GB', '35202-1234567-1', 'verified'),
       (11, 'CUS-T11',       'individual', 'Bilal',   'Malik', 'bilal@example.com',     '+442', 'PK', 'GB', '35202-7654321-3', 'verified'),
       (12, 'CUS-T12',       'individual', 'Usman',   'Raza',  'usman@example.com',     '+443', 'PK', 'GB', '35202-1111111-1', 'pending');

INSERT INTO wallets (wallet_id, customer_id, currency_code, wallet_type) VALUES
    (1, 1, 'GBP', 'settlement'), (2, 1, 'GBP', 'fee_revenue'),
    (3, 1, 'PKR', 'settlement'), (4, 1, 'PKR', 'fee_revenue'),
    (10, 10, 'GBP', 'customer'), (11, 11, 'GBP', 'customer'), (12, 11, 'PKR', 'customer'),
    (13, 12, 'GBP', 'customer');

INSERT INTO beneficiaries (beneficiary_id, customer_id, full_name, country_code, currency_code,
                           payout_method, provider_name, account_number)
VALUES (100, 10, 'Zainab Khan',  'PK', 'PKR', 'bank_deposit', 'HBL',        'PK36HABB0000001123456702'),
       (101, 11, 'Hamza Malik',  'PK', 'PKR', 'bank_deposit', 'Meezan Bank', 'PK36MEZN0000002123456702');

-- -----------------------------------------------------------------------------
-- Deposits
-- -----------------------------------------------------------------------------
CALL sp_deposit(10, 1000.00, 'app', 'dep-10-1', @dep1);
CALL t_assert('deposit credits the customer wallet',     (SELECT balance FROM wallets WHERE wallet_id = 10) = 1000.00);
CALL t_assert('deposit debits GBP settlement',           (SELECT balance FROM wallets WHERE wallet_id = 1) = -1000.00);
CALL t_assert('deposit writes two ledger lines',         (SELECT COUNT(*) FROM ledger_entries WHERE txn_id = @dep1) = 2);

CALL sp_deposit(10, 1000.00, 'app', 'dep-10-1', @dep1_retry);
CALL t_assert('idempotent retry returns the same txn',   @dep1_retry = @dep1);
CALL t_assert('idempotent retry moves no money',         (SELECT balance FROM wallets WHERE wallet_id = 10) = 1000.00);

CALL t_expect_error('deposit rejects zero amount',
    'CALL sp_deposit(10, 0, ''app'', ''dep-zero'', @x)', 'greater than zero');
CALL t_expect_error('deposit rejects a house wallet',
    'CALL sp_deposit(1, 50, ''app'', ''dep-house'', @x)', 'only allowed into customer wallets');
CALL t_expect_error('deposit rejects an unknown wallet',
    'CALL sp_deposit(999, 50, ''app'', ''dep-missing'', @x)', 'Wallet not found');

-- -----------------------------------------------------------------------------
-- Transfers
-- -----------------------------------------------------------------------------
CALL sp_transfer_funds(10, 11, 250.00, 'app', 'tr-1', @tr1);
CALL t_assert('transfer debits the sender',              (SELECT balance FROM wallets WHERE wallet_id = 10) = 750.00);
CALL t_assert('transfer credits the receiver',           (SELECT balance FROM wallets WHERE wallet_id = 11) = 250.00);
CALL t_assert('transfer ledger balance_after is right',
    (SELECT balance_after FROM ledger_entries WHERE txn_id = @tr1 AND wallet_id = 10) = 750.00);

CALL t_expect_error('transfer refuses to overdraw',
    'CALL sp_transfer_funds(10, 11, 10000, ''app'', ''tr-big'', @x)', 'Insufficient funds');
CALL t_assert('failed transfer leaves balances alone',   (SELECT balance FROM wallets WHERE wallet_id = 10) = 750.00);
CALL t_assert('failed transfer writes no transaction',   (SELECT COUNT(*) FROM transactions WHERE idempotency_key = 'tr-big') = 0);

CALL t_expect_error('transfer refuses currency mismatch',
    'CALL sp_transfer_funds(10, 12, 10, ''app'', ''tr-fx'', @x)', 'same currency');
CALL t_expect_error('transfer refuses same wallet',
    'CALL sp_transfer_funds(10, 10, 10, ''app'', ''tr-self'', @x)', 'must differ');

UPDATE wallets SET status = 'frozen' WHERE wallet_id = 11;
CALL t_expect_error('transfer refuses a frozen wallet',
    'CALL sp_transfer_funds(10, 11, 10, ''app'', ''tr-frozen'', @x)', 'not active');
UPDATE wallets SET status = 'active' WHERE wallet_id = 11;
CALL t_assert('wallet freeze/unfreeze is audited',
    (SELECT COUNT(*) FROM audit_log WHERE table_name = 'wallets' AND record_id = 11 AND action = 'UPDATE') = 2);

-- -----------------------------------------------------------------------------
-- Remittances
-- -----------------------------------------------------------------------------
CALL sp_send_remittance(10, 100, 100.00, 'app', 'rem-1', @rem1);
CALL t_assert('remittance debits amount + fee (0.99)',   (SELECT balance FROM wallets WHERE wallet_id = 10) = 649.01);
CALL t_assert('remittance holds amount in settlement',   (SELECT balance FROM wallets WHERE wallet_id = 1) = -900.00);
CALL t_assert('remittance books the fee as revenue',     (SELECT balance FROM wallets WHERE wallet_id = 2) = 0.99);
CALL t_assert('remittance starts pending',               (SELECT status FROM transactions WHERE txn_id = @rem1) = 'pending');
CALL t_assert('remittance locks in payout at 355.50',    (SELECT payout_amount FROM transactions WHERE txn_id = @rem1) = 35550.00);

CALL t_expect_error('remittance needs verified KYC',
    'CALL sp_send_remittance(13, 100, 10, ''app'', ''rem-kyc'', @x)', 'KYC must be verified');
CALL t_expect_error('remittance needs the sender''s own beneficiary',
    'CALL sp_send_remittance(10, 101, 10, ''app'', ''rem-ben'', @x)', 'Beneficiary not found');
CALL t_expect_error('remittance refuses to overdraw',
    'CALL sp_send_remittance(10, 100, 5000, ''app'', ''rem-big'', @x)', 'Insufficient funds');

-- Payout partner rejects it: refund amount + fee via a reversal.
CALL sp_complete_remittance(@rem1, FALSE, 'BENEFICIARY_ACCOUNT_INVALID');
CALL t_assert('failed remittance is marked failed',      (SELECT status FROM transactions WHERE txn_id = @rem1) = 'failed');
CALL t_assert('failed remittance is fully refunded',     (SELECT balance FROM wallets WHERE wallet_id = 10) = 750.00);
CALL t_assert('refund reverses the fee too',             (SELECT balance FROM wallets WHERE wallet_id = 2) = 0.00);
CALL t_assert('refund is a linked reversal transaction',
    (SELECT COUNT(*) FROM transactions WHERE reversal_of_txn_id = @rem1 AND txn_type = 'reversal' AND amount = 100.99) = 1);
CALL t_expect_error('a remittance completes only once',
    CONCAT('CALL sp_complete_remittance(', @rem1, ', TRUE, NULL)'), 'not pending');

-- Second remittance succeeds (fee band under 100 = 1.99).
CALL sp_send_remittance(10, 100, 50.00, 'web', 'rem-2', @rem2);
CALL sp_complete_remittance(@rem2, TRUE, NULL);
CALL t_assert('successful remittance is completed',      (SELECT status FROM transactions WHERE txn_id = @rem2) = 'completed');
CALL t_assert('small-band fee is 1.99',                  (SELECT balance FROM wallets WHERE wallet_id = 10) = 698.01);

-- -----------------------------------------------------------------------------
-- Ledger invariants
-- -----------------------------------------------------------------------------
CALL t_assert('per currency, all balances sum to zero',
    (SELECT COUNT(*) FROM (SELECT currency_code FROM wallets GROUP BY currency_code HAVING SUM(balance) <> 0) x) = 0);
CALL t_assert('every wallet balance equals its ledger total',
    (SELECT COUNT(*)
       FROM wallets w
       LEFT JOIN (SELECT wallet_id, SUM(IF(entry_type = 'credit', amount, -amount)) AS net
                    FROM ledger_entries GROUP BY wallet_id) l ON l.wallet_id = w.wallet_id
      WHERE w.balance <> COALESCE(l.net, 0)) = 0);
CALL t_assert('every transaction''s debits equal its credits',
    (SELECT COUNT(*) FROM (SELECT txn_id FROM ledger_entries GROUP BY txn_id
                            HAVING SUM(IF(entry_type = 'debit', amount, 0)) <> SUM(IF(entry_type = 'credit', amount, 0))) x) = 0);

-- -----------------------------------------------------------------------------
-- Immutability and audit triggers
-- -----------------------------------------------------------------------------
CALL t_expect_error('transactions cannot be deleted',
    CONCAT('DELETE FROM transactions WHERE txn_id = ', @tr1), 'cannot be deleted');
CALL t_expect_error('transaction amounts cannot change',
    CONCAT('UPDATE transactions SET amount = 1 WHERE txn_id = ', @tr1), 'immutable');
CALL t_expect_error('completed transactions cannot change status',
    CONCAT('UPDATE transactions SET status = ''pending'' WHERE txn_id = ', @tr1), 'Only pending');
CALL t_expect_error('ledger entries cannot be updated',
    'UPDATE ledger_entries SET amount = 1 WHERE entry_id = 1', 'immutable');
CALL t_expect_error('ledger entries cannot be deleted',
    'DELETE FROM ledger_entries WHERE entry_id = 1', 'immutable');
CALL t_expect_error('audit log cannot be tampered with',
    'DELETE FROM audit_log WHERE audit_id = 1', 'append-only');
CALL t_expect_error('wallets cannot be deleted',
    'DELETE FROM wallets WHERE wallet_id = 13', 'cannot be deleted');

UPDATE customers SET risk_rating = 'high' WHERE customer_id = 12;
CALL t_assert('customer changes are audited with the app user',
    (SELECT COUNT(*) FROM audit_log
      WHERE table_name = 'customers' AND record_id = 12 AND action = 'UPDATE'
        AND app_user = 'test-runner'
        AND new_row->>'$.risk_rating' = 'high' AND old_row->>'$.risk_rating' = 'low') = 1);
CALL t_assert('national ID is masked in the audit log',
    (SELECT new_row->>'$.national_id_number' FROM audit_log
      WHERE table_name = 'customers' AND record_id = 12 AND action = 'INSERT') = '***11-1');
CALL t_assert('remittance status changes are audited',
    (SELECT COUNT(*) FROM audit_log WHERE table_name = 'transactions' AND record_id IN (@rem1, @rem2)) = 2);

SELECT 'ALL TESTS PASSED' AS result;
