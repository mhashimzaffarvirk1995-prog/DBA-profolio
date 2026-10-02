-- =============================================================================
-- PayFlow schema — triggers
--
-- Two jobs:
--   1. Audit trail: changes to customers, KYC documents, beneficiaries, wallet
--      status and transaction status are written to audit_log as JSON
--      before/after images.
--   2. Immutability: money records are append-only. transactions may only
--      change status/failure_reason/completed_at; ledger_entries and
--      audit_log can never be updated or deleted through SQL DML.
--
-- Wallet balance changes are NOT audited here: every balance change already
-- has a ledger_entries row, which is a stricter audit trail than a trigger.
--
-- Apply this file AFTER the bulk data load (see Makefile): historical rows
-- loaded by the generator are not audit events, and LOAD DATA would otherwise
-- write millions of audit rows.
-- =============================================================================

DELIMITER $$

-- -----------------------------------------------------------------------------
-- customers  (national_id_number is masked in the audit copy)
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_customers_ai$$
CREATE TRIGGER trg_customers_ai AFTER INSERT ON customers FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('customers', NEW.customer_id, 'INSERT', NULL,
            JSON_OBJECT('customer_ref', NEW.customer_ref, 'customer_type', NEW.customer_type,
                        'first_name', NEW.first_name, 'last_name', NEW.last_name,
                        'email', NEW.email, 'phone', NEW.phone, 'date_of_birth', NEW.date_of_birth,
                        'nationality_country_code', NEW.nationality_country_code,
                        'residence_country_code', NEW.residence_country_code,
                        'national_id_number', CONCAT('***', RIGHT(NEW.national_id_number, 4)),
                        'status', NEW.status, 'kyc_status', NEW.kyc_status, 'risk_rating', NEW.risk_rating),
            USER(), @app_user, CONNECTION_ID());
END$$

DROP TRIGGER IF EXISTS trg_customers_au$$
CREATE TRIGGER trg_customers_au AFTER UPDATE ON customers FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('customers', NEW.customer_id, 'UPDATE',
            JSON_OBJECT('customer_ref', OLD.customer_ref, 'customer_type', OLD.customer_type,
                        'first_name', OLD.first_name, 'last_name', OLD.last_name,
                        'email', OLD.email, 'phone', OLD.phone, 'date_of_birth', OLD.date_of_birth,
                        'nationality_country_code', OLD.nationality_country_code,
                        'residence_country_code', OLD.residence_country_code,
                        'national_id_number', CONCAT('***', RIGHT(OLD.national_id_number, 4)),
                        'status', OLD.status, 'kyc_status', OLD.kyc_status, 'risk_rating', OLD.risk_rating),
            JSON_OBJECT('customer_ref', NEW.customer_ref, 'customer_type', NEW.customer_type,
                        'first_name', NEW.first_name, 'last_name', NEW.last_name,
                        'email', NEW.email, 'phone', NEW.phone, 'date_of_birth', NEW.date_of_birth,
                        'nationality_country_code', NEW.nationality_country_code,
                        'residence_country_code', NEW.residence_country_code,
                        'national_id_number', CONCAT('***', RIGHT(NEW.national_id_number, 4)),
                        'status', NEW.status, 'kyc_status', NEW.kyc_status, 'risk_rating', NEW.risk_rating),
            USER(), @app_user, CONNECTION_ID());
END$$

DROP TRIGGER IF EXISTS trg_customers_ad$$
CREATE TRIGGER trg_customers_ad AFTER DELETE ON customers FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('customers', OLD.customer_id, 'DELETE',
            JSON_OBJECT('customer_ref', OLD.customer_ref, 'first_name', OLD.first_name,
                        'last_name', OLD.last_name, 'email', OLD.email, 'status', OLD.status,
                        'kyc_status', OLD.kyc_status),
            NULL, USER(), @app_user, CONNECTION_ID());
END$$

-- -----------------------------------------------------------------------------
-- kyc_documents
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_kyc_documents_ai$$
CREATE TRIGGER trg_kyc_documents_ai AFTER INSERT ON kyc_documents FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('kyc_documents', NEW.kyc_document_id, 'INSERT', NULL,
            JSON_OBJECT('customer_id', NEW.customer_id, 'doc_type', NEW.doc_type,
                        'issuing_country_code', NEW.issuing_country_code, 'expiry_date', NEW.expiry_date,
                        'status', NEW.status, 'file_sha256', NEW.file_sha256),
            USER(), @app_user, CONNECTION_ID());
END$$

DROP TRIGGER IF EXISTS trg_kyc_documents_au$$
CREATE TRIGGER trg_kyc_documents_au AFTER UPDATE ON kyc_documents FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('kyc_documents', NEW.kyc_document_id, 'UPDATE',
            JSON_OBJECT('status', OLD.status, 'rejection_reason', OLD.rejection_reason,
                        'expiry_date', OLD.expiry_date, 'verified_at', OLD.verified_at,
                        'file_sha256', OLD.file_sha256),
            JSON_OBJECT('status', NEW.status, 'rejection_reason', NEW.rejection_reason,
                        'expiry_date', NEW.expiry_date, 'verified_at', NEW.verified_at,
                        'file_sha256', NEW.file_sha256),
            USER(), @app_user, CONNECTION_ID());
END$$

-- -----------------------------------------------------------------------------
-- beneficiaries
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_beneficiaries_ai$$
CREATE TRIGGER trg_beneficiaries_ai AFTER INSERT ON beneficiaries FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('beneficiaries', NEW.beneficiary_id, 'INSERT', NULL,
            JSON_OBJECT('customer_id', NEW.customer_id, 'full_name', NEW.full_name,
                        'country_code', NEW.country_code, 'payout_method', NEW.payout_method,
                        'provider_name', NEW.provider_name, 'account_number', NEW.account_number,
                        'mobile_number', NEW.mobile_number, 'is_active', NEW.is_active),
            USER(), @app_user, CONNECTION_ID());
END$$

DROP TRIGGER IF EXISTS trg_beneficiaries_au$$
CREATE TRIGGER trg_beneficiaries_au AFTER UPDATE ON beneficiaries FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('beneficiaries', NEW.beneficiary_id, 'UPDATE',
            JSON_OBJECT('full_name', OLD.full_name, 'payout_method', OLD.payout_method,
                        'provider_name', OLD.provider_name, 'account_number', OLD.account_number,
                        'mobile_number', OLD.mobile_number, 'is_active', OLD.is_active),
            JSON_OBJECT('full_name', NEW.full_name, 'payout_method', NEW.payout_method,
                        'provider_name', NEW.provider_name, 'account_number', NEW.account_number,
                        'mobile_number', NEW.mobile_number, 'is_active', NEW.is_active),
            USER(), @app_user, CONNECTION_ID());
END$$

DROP TRIGGER IF EXISTS trg_beneficiaries_ad$$
CREATE TRIGGER trg_beneficiaries_ad AFTER DELETE ON beneficiaries FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('beneficiaries', OLD.beneficiary_id, 'DELETE',
            JSON_OBJECT('customer_id', OLD.customer_id, 'full_name', OLD.full_name,
                        'account_number', OLD.account_number, 'mobile_number', OLD.mobile_number),
            NULL, USER(), @app_user, CONNECTION_ID());
END$$

-- -----------------------------------------------------------------------------
-- wallets  (status changes only — freezes and closures are what auditors ask about)
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_wallets_ai$$
CREATE TRIGGER trg_wallets_ai AFTER INSERT ON wallets FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('wallets', NEW.wallet_id, 'INSERT', NULL,
            JSON_OBJECT('customer_id', NEW.customer_id, 'currency_code', NEW.currency_code,
                        'wallet_type', NEW.wallet_type, 'status', NEW.status),
            USER(), @app_user, CONNECTION_ID());
END$$

DROP TRIGGER IF EXISTS trg_wallets_au$$
CREATE TRIGGER trg_wallets_au AFTER UPDATE ON wallets FOR EACH ROW
BEGIN
    IF NOT (OLD.status <=> NEW.status) THEN
        INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
        VALUES ('wallets', NEW.wallet_id, 'UPDATE',
                JSON_OBJECT('status', OLD.status, 'balance', OLD.balance),
                JSON_OBJECT('status', NEW.status, 'balance', NEW.balance),
                USER(), @app_user, CONNECTION_ID());
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_wallets_bd$$
CREATE TRIGGER trg_wallets_bd BEFORE DELETE ON wallets FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Wallets cannot be deleted; set status = ''closed''';
END$$

-- -----------------------------------------------------------------------------
-- transactions  (append-only; only the lifecycle columns may change)
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_transactions_bu$$
CREATE TRIGGER trg_transactions_bu BEFORE UPDATE ON transactions FOR EACH ROW
BEGIN
    IF NOT (OLD.txn_ref              <=> NEW.txn_ref)
    OR NOT (OLD.idempotency_key      <=> NEW.idempotency_key)
    OR NOT (OLD.txn_type             <=> NEW.txn_type)
    OR NOT (OLD.channel              <=> NEW.channel)
    OR NOT (OLD.source_wallet_id     <=> NEW.source_wallet_id)
    OR NOT (OLD.dest_wallet_id       <=> NEW.dest_wallet_id)
    OR NOT (OLD.beneficiary_id       <=> NEW.beneficiary_id)
    OR NOT (OLD.reversal_of_txn_id   <=> NEW.reversal_of_txn_id)
    OR NOT (OLD.amount               <=> NEW.amount)
    OR NOT (OLD.currency_code        <=> NEW.currency_code)
    OR NOT (OLD.fee_amount           <=> NEW.fee_amount)
    OR NOT (OLD.fx_rate_id           <=> NEW.fx_rate_id)
    OR NOT (OLD.payout_amount        <=> NEW.payout_amount)
    OR NOT (OLD.payout_currency_code <=> NEW.payout_currency_code)
    OR NOT (OLD.created_at           <=> NEW.created_at) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transactions are immutable; only status, failure_reason and completed_at may change';
    END IF;
    IF OLD.status <> 'pending' AND NOT (OLD.status <=> NEW.status) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only pending transactions can change status';
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_transactions_au$$
CREATE TRIGGER trg_transactions_au AFTER UPDATE ON transactions FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_row, new_row, db_user, app_user, connection_id)
    VALUES ('transactions', NEW.txn_id, 'UPDATE',
            JSON_OBJECT('status', OLD.status, 'failure_reason', OLD.failure_reason, 'completed_at', OLD.completed_at),
            JSON_OBJECT('status', NEW.status, 'failure_reason', NEW.failure_reason, 'completed_at', NEW.completed_at),
            USER(), @app_user, CONNECTION_ID());
END$$

DROP TRIGGER IF EXISTS trg_transactions_bd$$
CREATE TRIGGER trg_transactions_bd BEFORE DELETE ON transactions FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transactions cannot be deleted; post a reversal instead';
END$$

-- -----------------------------------------------------------------------------
-- ledger_entries and audit_log  (fully immutable)
-- Retention purges, when needed, are a DBA operation (e.g. partition drop),
-- not application DML.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_ledger_entries_bu$$
CREATE TRIGGER trg_ledger_entries_bu BEFORE UPDATE ON ledger_entries FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger entries are immutable';
END$$

DROP TRIGGER IF EXISTS trg_ledger_entries_bd$$
CREATE TRIGGER trg_ledger_entries_bd BEFORE DELETE ON ledger_entries FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger entries are immutable';
END$$

DROP TRIGGER IF EXISTS trg_audit_log_bu$$
CREATE TRIGGER trg_audit_log_bu BEFORE UPDATE ON audit_log FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Audit log is append-only';
END$$

DROP TRIGGER IF EXISTS trg_audit_log_bd$$
CREATE TRIGGER trg_audit_log_bd BEFORE DELETE ON audit_log FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Audit log is append-only';
END$$

DELIMITER ;
