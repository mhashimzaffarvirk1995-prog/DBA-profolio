-- =============================================================================
-- PayFlow schema — stored procedures
--
-- Public API (what the app account will be granted EXECUTE on):
--   sp_deposit              cash/card in to a customer wallet
--   sp_transfer_funds       same-currency wallet-to-wallet transfer
--   sp_send_remittance      cross-border send to a beneficiary (funds held, status pending)
--   sp_complete_remittance  payout partner callback: completes, or fails and refunds
--   sp_wallet_statement     ledger lines for a wallet over a date range
-- Internal helpers:
--   sp_lock_wallets, sp_post_entry
--
-- Conventions
--   * Each public procedure owns its transaction (START TRANSACTION ... COMMIT)
--     and rolls back + re-raises on any error. Call them with autocommit on,
--     not inside an open transaction — START TRANSACTION would commit it.
--   * Business-rule violations raise SQLSTATE 45000 with a readable message.
--   * credit = wallet balance goes up, debit = goes down. Every movement posts
--     equal debits and credits, so per currency SUM(wallets.balance) stays 0.
--
-- Locking
--   Every procedure that changes balances first locks ALL wallets it will
--   touch, in ascending wallet_id order, via sp_lock_wallets. Because every
--   code path takes locks in the same global order, two concurrent transfers
--   A->B and B->A queue behind each other instead of deadlocking.
-- =============================================================================

DELIMITER $$

-- -----------------------------------------------------------------------------
-- Internal: lock up to three wallets in ascending wallet_id order.
-- Pass 0 for unused slots. Raises if any non-zero id does not exist.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_lock_wallets$$
CREATE PROCEDURE sp_lock_wallets(
    IN p_a BIGINT UNSIGNED,
    IN p_b BIGINT UNSIGNED,
    IN p_c BIGINT UNSIGNED)
BEGIN
    DECLARE v_lo, v_mid, v_hi, v_got BIGINT UNSIGNED;
    DECLARE v_missing BOOLEAN DEFAULT FALSE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_missing = TRUE;

    SET v_lo  = LEAST(p_a, p_b, p_c);
    SET v_hi  = GREATEST(p_a, p_b, p_c);
    SET v_mid = p_a + p_b + p_c - v_lo - v_hi;

    -- Skip the 0 placeholders: a locking read on a missing key would take a
    -- gap lock for nothing.
    IF v_lo > 0 THEN
        SELECT wallet_id INTO v_got FROM wallets WHERE wallet_id = v_lo FOR UPDATE;
    END IF;
    IF v_mid > 0 AND v_mid <> v_lo THEN
        SELECT wallet_id INTO v_got FROM wallets WHERE wallet_id = v_mid FOR UPDATE;
    END IF;
    IF v_hi <> v_mid THEN
        SELECT wallet_id INTO v_got FROM wallets WHERE wallet_id = v_hi FOR UPDATE;
    END IF;

    IF v_missing THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallet not found';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- Internal: apply one ledger line and move the cached balance with it.
-- Caller must already hold the wallet's row lock.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_post_entry$$
CREATE PROCEDURE sp_post_entry(
    IN p_txn_id     BIGINT UNSIGNED,
    IN p_wallet_id  BIGINT UNSIGNED,
    IN p_entry_type VARCHAR(6),
    IN p_amount     DECIMAL(19,4),
    IN p_at         DATETIME(6))
BEGIN
    DECLARE v_balance DECIMAL(19,4);

    -- chk_wallet_no_overdraft backs this up if a caller forgets its own check.
    UPDATE wallets
       SET balance    = balance + IF(p_entry_type = 'credit', p_amount, -p_amount),
           updated_at = p_at
     WHERE wallet_id = p_wallet_id;

    -- Our own uncommitted change is visible to us.
    SELECT balance INTO v_balance FROM wallets WHERE wallet_id = p_wallet_id;

    INSERT INTO ledger_entries (txn_id, wallet_id, entry_type, amount, balance_after, created_at)
    VALUES (p_txn_id, p_wallet_id, p_entry_type, p_amount, v_balance, p_at);
END$$

-- -----------------------------------------------------------------------------
-- sp_deposit: credit a customer wallet; the settlement wallet takes the debit.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_deposit$$
CREATE PROCEDURE sp_deposit(
    IN  p_wallet_id       BIGINT UNSIGNED,
    IN  p_amount          DECIMAL(19,4),
    IN  p_channel         VARCHAR(8),
    IN  p_idempotency_key VARCHAR(64),
    OUT p_txn_id          BIGINT UNSIGNED)
proc: BEGIN
    DECLARE v_now             DATETIME(6) DEFAULT UTC_TIMESTAMP(6);
    DECLARE v_currency        CHAR(3);
    DECLARE v_wallet_type     VARCHAR(16);
    DECLARE v_wallet_status   VARCHAR(16);
    DECLARE v_customer_status VARCHAR(16);
    DECLARE v_settlement_id   BIGINT UNSIGNED;

    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;   -- missing rows leave variables NULL
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;

    -- A retry with the same key returns the original transaction.
    SET p_txn_id = (SELECT txn_id FROM transactions WHERE idempotency_key = p_idempotency_key);
    IF p_txn_id IS NOT NULL THEN
        LEAVE proc;
    END IF;

    SET v_currency = (SELECT currency_code FROM wallets WHERE wallet_id = p_wallet_id);
    IF v_currency IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallet not found';
    END IF;

    SET v_settlement_id = (
        SELECT w.wallet_id
          FROM customers c
          JOIN wallets w ON w.customer_id = c.customer_id
                        AND w.currency_code = v_currency
                        AND w.wallet_type = 'settlement'
         WHERE c.customer_ref = 'PAYFLOW-HOUSE');
    IF v_settlement_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No settlement wallet for this currency';
    END IF;

    START TRANSACTION;
    CALL sp_lock_wallets(p_wallet_id, v_settlement_id, 0);

    SELECT w.wallet_type, w.status, c.status
      INTO v_wallet_type, v_wallet_status, v_customer_status
      FROM wallets w
      JOIN customers c ON c.customer_id = w.customer_id
     WHERE w.wallet_id = p_wallet_id
       FOR UPDATE OF w;

    IF v_wallet_type <> 'customer' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposits are only allowed into customer wallets';
    END IF;
    IF v_wallet_status <> 'active' OR v_customer_status <> 'active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallet or customer is not active';
    END IF;

    INSERT INTO transactions
        (txn_ref, idempotency_key, txn_type, status, channel,
         dest_wallet_id, amount, currency_code, created_at, completed_at)
    VALUES
        (CONCAT('PF', DATE_FORMAT(v_now, '%y%m%d'), HEX(RANDOM_BYTES(5))), p_idempotency_key,
         'deposit', 'completed', p_channel,
         p_wallet_id, p_amount, v_currency, v_now, v_now);
    SET p_txn_id = LAST_INSERT_ID();

    CALL sp_post_entry(p_txn_id, v_settlement_id, 'debit',  p_amount, v_now);
    CALL sp_post_entry(p_txn_id, p_wallet_id,     'credit', p_amount, v_now);

    COMMIT;
END$$

-- -----------------------------------------------------------------------------
-- sp_transfer_funds: move money between two customer wallets of the same
-- currency. Fails, with nothing written, on insufficient funds.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_transfer_funds$$
CREATE PROCEDURE sp_transfer_funds(
    IN  p_from_wallet_id  BIGINT UNSIGNED,
    IN  p_to_wallet_id    BIGINT UNSIGNED,
    IN  p_amount          DECIMAL(19,4),
    IN  p_channel         VARCHAR(8),
    IN  p_idempotency_key VARCHAR(64),
    OUT p_txn_id          BIGINT UNSIGNED)
proc: BEGIN
    DECLARE v_now                  DATETIME(6) DEFAULT UTC_TIMESTAMP(6);
    DECLARE v_from_currency        CHAR(3);
    DECLARE v_to_currency          CHAR(3);
    DECLARE v_from_balance         DECIMAL(19,4);
    DECLARE v_from_type, v_to_type VARCHAR(16);
    DECLARE v_from_status, v_to_status VARCHAR(16);
    DECLARE v_from_customer_status, v_to_customer_status VARCHAR(16);

    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;
    IF p_from_wallet_id = p_to_wallet_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source and destination wallets must differ';
    END IF;

    SET p_txn_id = (SELECT txn_id FROM transactions WHERE idempotency_key = p_idempotency_key);
    IF p_txn_id IS NOT NULL THEN
        LEAVE proc;
    END IF;

    -- currency_code never changes after a wallet is created, so it is safe to
    -- read before taking locks.
    SET v_from_currency = (SELECT currency_code FROM wallets WHERE wallet_id = p_from_wallet_id);
    SET v_to_currency   = (SELECT currency_code FROM wallets WHERE wallet_id = p_to_wallet_id);
    IF v_from_currency IS NULL OR v_to_currency IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallet not found';
    END IF;
    IF v_from_currency <> v_to_currency THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfers must be in the same currency';
    END IF;

    START TRANSACTION;
    CALL sp_lock_wallets(p_from_wallet_id, p_to_wallet_id, 0);

    -- Locking reads always return the latest committed row, never a stale snapshot.
    SELECT w.balance, w.wallet_type, w.status, c.status
      INTO v_from_balance, v_from_type, v_from_status, v_from_customer_status
      FROM wallets w
      JOIN customers c ON c.customer_id = w.customer_id
     WHERE w.wallet_id = p_from_wallet_id
       FOR UPDATE OF w;

    SELECT w.wallet_type, w.status, c.status
      INTO v_to_type, v_to_status, v_to_customer_status
      FROM wallets w
      JOIN customers c ON c.customer_id = w.customer_id
     WHERE w.wallet_id = p_to_wallet_id
       FOR UPDATE OF w;

    IF v_from_type <> 'customer' OR v_to_type <> 'customer' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfers are only allowed between customer wallets';
    END IF;
    IF v_from_status <> 'active' OR v_to_status <> 'active'
       OR v_from_customer_status <> 'active' OR v_to_customer_status <> 'active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallet or customer is not active';
    END IF;
    IF v_from_balance < p_amount THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    INSERT INTO transactions
        (txn_ref, idempotency_key, txn_type, status, channel,
         source_wallet_id, dest_wallet_id, amount, currency_code, created_at, completed_at)
    VALUES
        (CONCAT('PF', DATE_FORMAT(v_now, '%y%m%d'), HEX(RANDOM_BYTES(5))), p_idempotency_key,
         'transfer', 'completed', p_channel,
         p_from_wallet_id, p_to_wallet_id, p_amount, v_from_currency, v_now, v_now);
    SET p_txn_id = LAST_INSERT_ID();

    CALL sp_post_entry(p_txn_id, p_from_wallet_id, 'debit',  p_amount, v_now);
    CALL sp_post_entry(p_txn_id, p_to_wallet_id,   'credit', p_amount, v_now);

    COMMIT;
END$$

-- -----------------------------------------------------------------------------
-- sp_send_remittance: debit amount + fee from the sender's wallet, hold the
-- amount in settlement until the payout partner confirms, book the fee as
-- revenue. Locks in the FX rate and fee at send time. Status starts 'pending'.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_send_remittance$$
CREATE PROCEDURE sp_send_remittance(
    IN  p_wallet_id       BIGINT UNSIGNED,
    IN  p_beneficiary_id  BIGINT UNSIGNED,
    IN  p_amount          DECIMAL(19,4),
    IN  p_channel         VARCHAR(8),
    IN  p_idempotency_key VARCHAR(64),
    OUT p_txn_id          BIGINT UNSIGNED)
proc: BEGIN
    DECLARE v_now                 DATETIME(6) DEFAULT UTC_TIMESTAMP(6);
    DECLARE v_customer_id         BIGINT UNSIGNED;
    DECLARE v_currency            CHAR(3);
    DECLARE v_wallet_type         VARCHAR(16);
    DECLARE v_wallet_status       VARCHAR(16);
    DECLARE v_balance             DECIMAL(19,4);
    DECLARE v_customer_status     VARCHAR(16);
    DECLARE v_kyc_status          VARCHAR(16);
    DECLARE v_ben_customer_id     BIGINT UNSIGNED;
    DECLARE v_ben_country         CHAR(2);
    DECLARE v_payout_currency     CHAR(3);
    DECLARE v_ben_active          BOOLEAN;
    DECLARE v_fee                 DECIMAL(19,4);
    DECLARE v_rate_id             BIGINT UNSIGNED;
    DECLARE v_rate                DECIMAL(18,8);
    DECLARE v_settlement_id       BIGINT UNSIGNED;
    DECLARE v_fee_wallet_id       BIGINT UNSIGNED;

    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;

    SET p_txn_id = (SELECT txn_id FROM transactions WHERE idempotency_key = p_idempotency_key);
    IF p_txn_id IS NOT NULL THEN
        LEAVE proc;
    END IF;

    -- Who is sending, and are they allowed to?
    SELECT w.customer_id, w.currency_code, c.status, c.kyc_status
      INTO v_customer_id, v_currency, v_customer_status, v_kyc_status
      FROM wallets w
      JOIN customers c ON c.customer_id = w.customer_id
     WHERE w.wallet_id = p_wallet_id;
    IF v_customer_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallet not found';
    END IF;
    IF v_customer_status <> 'active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer is not active';
    END IF;
    IF v_kyc_status <> 'verified' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'KYC must be verified before sending a remittance';
    END IF;

    -- To whom?
    SELECT customer_id, country_code, currency_code, is_active
      INTO v_ben_customer_id, v_ben_country, v_payout_currency, v_ben_active
      FROM beneficiaries
     WHERE beneficiary_id = p_beneficiary_id;
    IF v_ben_customer_id IS NULL OR v_ben_customer_id <> v_customer_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary not found for this customer';
    END IF;
    IF NOT v_ben_active THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Beneficiary is not active';
    END IF;

    -- Price it: fee band and the FX rate in force right now.
    SET v_fee = (
        SELECT fee_amount
          FROM remittance_fees
         WHERE currency_code = v_currency
           AND dest_country_code = v_ben_country
           AND p_amount >= min_amount
           AND p_amount <  max_amount);
    IF v_fee IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Corridor not supported for this amount';
    END IF;

    SELECT rate_id, customer_rate
      INTO v_rate_id, v_rate
      FROM exchange_rates
     WHERE base_currency_code = v_currency
       AND quote_currency_code = v_payout_currency
       AND valid_from <= v_now
     ORDER BY valid_from DESC
     LIMIT 1;
    IF v_rate_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No exchange rate for this corridor';
    END IF;

    SELECT MAX(IF(w.wallet_type = 'settlement',  w.wallet_id, NULL)),
           MAX(IF(w.wallet_type = 'fee_revenue', w.wallet_id, NULL))
      INTO v_settlement_id, v_fee_wallet_id
      FROM customers c
      JOIN wallets w ON w.customer_id = c.customer_id AND w.currency_code = v_currency
     WHERE c.customer_ref = 'PAYFLOW-HOUSE';
    IF v_settlement_id IS NULL OR v_fee_wallet_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'House wallets missing for this currency';
    END IF;

    START TRANSACTION;
    CALL sp_lock_wallets(p_wallet_id, v_settlement_id, v_fee_wallet_id);

    SELECT balance, wallet_type, status
      INTO v_balance, v_wallet_type, v_wallet_status
      FROM wallets
     WHERE wallet_id = p_wallet_id
       FOR UPDATE;

    IF v_wallet_type <> 'customer' OR v_wallet_status <> 'active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallet is not an active customer wallet';
    END IF;
    IF v_balance < p_amount + v_fee THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    INSERT INTO transactions
        (txn_ref, idempotency_key, txn_type, status, channel,
         source_wallet_id, beneficiary_id, amount, currency_code, fee_amount,
         fx_rate_id, payout_amount, payout_currency_code, created_at)
    VALUES
        (CONCAT('PF', DATE_FORMAT(v_now, '%y%m%d'), HEX(RANDOM_BYTES(5))), p_idempotency_key,
         'remittance', 'pending', p_channel,
         p_wallet_id, p_beneficiary_id, p_amount, v_currency, v_fee,
         v_rate_id, ROUND(p_amount * v_rate, 2), v_payout_currency, v_now);
    SET p_txn_id = LAST_INSERT_ID();

    CALL sp_post_entry(p_txn_id, p_wallet_id,     'debit',  p_amount + v_fee, v_now);
    CALL sp_post_entry(p_txn_id, v_settlement_id, 'credit', p_amount,         v_now);
    IF v_fee > 0 THEN
        CALL sp_post_entry(p_txn_id, v_fee_wallet_id, 'credit', v_fee, v_now);
    END IF;

    COMMIT;
END$$

-- -----------------------------------------------------------------------------
-- sp_complete_remittance: called when the payout partner reports back.
--   success -> status 'completed'
--   failure -> status 'failed' and a 'reversal' transaction refunds amount + fee
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_complete_remittance$$
CREATE PROCEDURE sp_complete_remittance(
    IN p_txn_id         BIGINT UNSIGNED,
    IN p_success        BOOLEAN,
    IN p_failure_reason VARCHAR(64))
BEGIN
    DECLARE v_now           DATETIME(6) DEFAULT UTC_TIMESTAMP(6);
    DECLARE v_type          VARCHAR(16);
    DECLARE v_status        VARCHAR(16);
    DECLARE v_wallet_id     BIGINT UNSIGNED;
    DECLARE v_amount        DECIMAL(19,4);
    DECLARE v_fee           DECIMAL(19,4);
    DECLARE v_currency      CHAR(3);
    DECLARE v_settlement_id BIGINT UNSIGNED;
    DECLARE v_fee_wallet_id BIGINT UNSIGNED;
    DECLARE v_reversal_id   BIGINT UNSIGNED;

    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT p_success AND p_failure_reason IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A failure reason is required';
    END IF;

    START TRANSACTION;

    -- Lock the transaction row first so two callbacks for the same remittance
    -- cannot both act on it.
    SELECT txn_type, status, source_wallet_id, amount, fee_amount, currency_code
      INTO v_type, v_status, v_wallet_id, v_amount, v_fee, v_currency
      FROM transactions
     WHERE txn_id = p_txn_id
       FOR UPDATE;

    IF v_type IS NULL OR v_type <> 'remittance' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Remittance not found';
    END IF;
    IF v_status <> 'pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Remittance is not pending';
    END IF;

    IF p_success THEN
        UPDATE transactions
           SET status = 'completed', completed_at = v_now
         WHERE txn_id = p_txn_id;
    ELSE
        SELECT MAX(IF(w.wallet_type = 'settlement',  w.wallet_id, NULL)),
               MAX(IF(w.wallet_type = 'fee_revenue', w.wallet_id, NULL))
          INTO v_settlement_id, v_fee_wallet_id
          FROM customers c
          JOIN wallets w ON w.customer_id = c.customer_id AND w.currency_code = v_currency
         WHERE c.customer_ref = 'PAYFLOW-HOUSE';

        CALL sp_lock_wallets(v_wallet_id, v_settlement_id, v_fee_wallet_id);

        UPDATE transactions
           SET status = 'failed', failure_reason = p_failure_reason, completed_at = v_now
         WHERE txn_id = p_txn_id;

        INSERT INTO transactions
            (txn_ref, txn_type, status, channel, dest_wallet_id, reversal_of_txn_id,
             amount, currency_code, created_at, completed_at)
        VALUES
            (CONCAT('PF', DATE_FORMAT(v_now, '%y%m%d'), HEX(RANDOM_BYTES(5))), 'reversal', 'completed', 'api',
             v_wallet_id, p_txn_id, v_amount + v_fee, v_currency, v_now, v_now);
        SET v_reversal_id = LAST_INSERT_ID();

        CALL sp_post_entry(v_reversal_id, v_settlement_id, 'debit',  v_amount,         v_now);
        IF v_fee > 0 THEN
            CALL sp_post_entry(v_reversal_id, v_fee_wallet_id, 'debit', v_fee,         v_now);
        END IF;
        CALL sp_post_entry(v_reversal_id, v_wallet_id,     'credit', v_amount + v_fee, v_now);
    END IF;

    COMMIT;
END$$

-- -----------------------------------------------------------------------------
-- sp_wallet_statement: ledger lines for one wallet, [p_from, p_to).
-- This is the "monthly statement" query tracked in the performance phase.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_wallet_statement$$
CREATE PROCEDURE sp_wallet_statement(
    IN p_wallet_id BIGINT UNSIGNED,
    IN p_from      DATETIME,
    IN p_to        DATETIME)
BEGIN
    SELECT le.created_at,
           t.txn_ref,
           t.txn_type,
           t.status,
           le.entry_type,
           le.amount,
           le.balance_after
      FROM ledger_entries le
      JOIN transactions t ON t.txn_id = le.txn_id
     WHERE le.wallet_id = p_wallet_id
       AND le.created_at >= p_from
       AND le.created_at <  p_to
     ORDER BY le.entry_id;
END$$

DELIMITER ;
