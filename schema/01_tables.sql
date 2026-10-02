-- =============================================================================
-- PayFlow schema — tables
-- MySQL 8.4 LTS, InnoDB, utf8mb4. All timestamps are UTC.
--
-- Money is always DECIMAL(19,4), never FLOAT/DOUBLE.
-- Balances move only through ledger_entries (double-entry): every completed
-- money movement writes balanced debit/credit rows, so for each currency
-- SUM(wallets.balance) = 0 across customer + house (system) wallets.
--
-- Run against an empty database; the Makefile picks which one.
-- =============================================================================

SET NAMES utf8mb4;

-- -----------------------------------------------------------------------------
-- Reference data
-- -----------------------------------------------------------------------------

CREATE TABLE currencies (
    currency_code   CHAR(3)          NOT NULL,
    name            VARCHAR(64)      NOT NULL,
    minor_units     TINYINT UNSIGNED NOT NULL DEFAULT 2,
    PRIMARY KEY (currency_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE countries (
    country_code        CHAR(2)      NOT NULL,
    name                VARCHAR(64)  NOT NULL,
    currency_code       CHAR(3)      NOT NULL,
    dial_code           VARCHAR(6)   NOT NULL,
    is_send_market      BOOLEAN      NOT NULL DEFAULT FALSE,
    is_receive_market   BOOLEAN      NOT NULL DEFAULT FALSE,
    PRIMARY KEY (country_code),
    CONSTRAINT fk_countries_currency FOREIGN KEY (currency_code) REFERENCES currencies (currency_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Customer-facing FX rates. One row per currency pair per publication time;
-- the rate in force at time T is the latest row with valid_from <= T.
CREATE TABLE exchange_rates (
    rate_id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    base_currency_code  CHAR(3)         NOT NULL,
    quote_currency_code CHAR(3)         NOT NULL,
    mid_rate            DECIMAL(18,8)   NOT NULL,
    customer_rate       DECIMAL(18,8)   NOT NULL,   -- mid minus PayFlow's FX margin
    source              VARCHAR(32)     NOT NULL,
    valid_from          DATETIME        NOT NULL,
    PRIMARY KEY (rate_id),
    UNIQUE KEY uq_rate_pair_time (base_currency_code, quote_currency_code, valid_from),
    KEY idx_rate_quote (quote_currency_code),
    CONSTRAINT fk_rate_base  FOREIGN KEY (base_currency_code)  REFERENCES currencies (currency_code),
    CONSTRAINT fk_rate_quote FOREIGN KEY (quote_currency_code) REFERENCES currencies (currency_code),
    CONSTRAINT chk_rate_pair     CHECK (base_currency_code <> quote_currency_code),
    CONSTRAINT chk_rate_positive CHECK (mid_rate > 0 AND customer_rate > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Flat remittance fee by send currency, destination country and amount band.
-- Bands are half-open: min_amount <= amount < max_amount.
CREATE TABLE remittance_fees (
    fee_id              INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    currency_code       CHAR(3)       NOT NULL,
    dest_country_code   CHAR(2)       NOT NULL,
    min_amount          DECIMAL(19,4) NOT NULL,
    max_amount          DECIMAL(19,4) NOT NULL,
    fee_amount          DECIMAL(19,4) NOT NULL,
    PRIMARY KEY (fee_id),
    UNIQUE KEY uq_fee_band (currency_code, dest_country_code, min_amount),
    KEY idx_fee_dest (dest_country_code),
    CONSTRAINT fk_fee_currency FOREIGN KEY (currency_code)     REFERENCES currencies (currency_code),
    CONSTRAINT fk_fee_country  FOREIGN KEY (dest_country_code) REFERENCES countries (country_code),
    CONSTRAINT chk_fee_band    CHECK (min_amount >= 0 AND max_amount > min_amount AND fee_amount >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Customers and KYC
-- -----------------------------------------------------------------------------

-- customer_type 'system' is PayFlow itself: it owns the house wallets
-- (settlement and fee revenue) that sit on the other side of every entry.
CREATE TABLE customers (
    customer_id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_ref                VARCHAR(16)     NOT NULL,
    customer_type               ENUM('individual','system') NOT NULL DEFAULT 'individual',
    first_name                  VARCHAR(64)     NOT NULL,
    last_name                   VARCHAR(64)     NOT NULL,
    email                       VARCHAR(128)    NOT NULL,
    phone                       VARCHAR(20)     NOT NULL,
    date_of_birth               DATE            NULL,
    nationality_country_code    CHAR(2)         NOT NULL,
    residence_country_code      CHAR(2)         NOT NULL,
    national_id_number          VARCHAR(32)     NULL,   -- PII: encrypted/masked in the security phase
    status                      ENUM('active','suspended','closed') NOT NULL DEFAULT 'active',
    kyc_status                  ENUM('not_started','pending','verified','rejected') NOT NULL DEFAULT 'not_started',
    risk_rating                 ENUM('low','medium','high') NOT NULL DEFAULT 'low',
    created_at                  DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at                  DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (customer_id),
    UNIQUE KEY uq_customer_ref (customer_ref),
    UNIQUE KEY uq_customer_email (email),
    KEY idx_customer_name (last_name, first_name),
    KEY idx_customer_phone (phone),
    CONSTRAINT fk_customer_nationality FOREIGN KEY (nationality_country_code) REFERENCES countries (country_code),
    CONSTRAINT fk_customer_residence   FOREIGN KEY (residence_country_code)   REFERENCES countries (country_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE kyc_documents (
    kyc_document_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id             BIGINT UNSIGNED NOT NULL,
    doc_type                ENUM('passport','national_id','residence_permit','driving_licence','proof_of_address') NOT NULL,
    doc_number              VARCHAR(32)     NULL,       -- proof_of_address has no number
    issuing_country_code    CHAR(2)         NOT NULL,
    issue_date              DATE            NULL,
    expiry_date             DATE            NULL,
    status                  ENUM('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
    rejection_reason        VARCHAR(64)     NULL,
    file_sha256             CHAR(64)        NOT NULL,   -- hash of the scanned file held in object storage
    verified_at             DATETIME(6)     NULL,
    created_at              DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (kyc_document_id),
    KEY idx_kyc_customer_status (customer_id, status),
    KEY idx_kyc_issuing_country (issuing_country_code),
    CONSTRAINT fk_kyc_customer FOREIGN KEY (customer_id)          REFERENCES customers (customer_id),
    CONSTRAINT fk_kyc_country  FOREIGN KEY (issuing_country_code) REFERENCES countries (country_code),
    CONSTRAINT chk_kyc_dates   CHECK (expiry_date IS NULL OR issue_date IS NULL OR expiry_date > issue_date),
    CONSTRAINT chk_kyc_rejected_reason CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Wallets and beneficiaries
-- -----------------------------------------------------------------------------

-- A customer holds at most one wallet per currency. House wallets (owned by
-- the system customer) may go negative — e.g. the settlement wallet is the
-- contra side of customer deposits — so the no-overdraft rule applies to
-- customer wallets only.
CREATE TABLE wallets (
    wallet_id       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id     BIGINT UNSIGNED NOT NULL,
    currency_code   CHAR(3)         NOT NULL,
    wallet_type     ENUM('customer','settlement','fee_revenue') NOT NULL DEFAULT 'customer',
    balance         DECIMAL(19,4)   NOT NULL DEFAULT 0,
    status          ENUM('active','frozen','closed') NOT NULL DEFAULT 'active',
    created_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (wallet_id),
    UNIQUE KEY uq_wallet_owner_currency (customer_id, currency_code, wallet_type),
    KEY idx_wallet_currency (currency_code),
    CONSTRAINT fk_wallet_customer FOREIGN KEY (customer_id)   REFERENCES customers (customer_id),
    CONSTRAINT fk_wallet_currency FOREIGN KEY (currency_code) REFERENCES currencies (currency_code),
    CONSTRAINT chk_wallet_no_overdraft CHECK (wallet_type <> 'customer' OR balance >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE beneficiaries (
    beneficiary_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id     BIGINT UNSIGNED NOT NULL,
    full_name       VARCHAR(128)    NOT NULL,
    country_code    CHAR(2)         NOT NULL,
    currency_code   CHAR(3)         NOT NULL,
    payout_method   ENUM('bank_deposit','mobile_wallet','cash_pickup') NOT NULL,
    provider_name   VARCHAR(64)     NULL,   -- bank or mobile-wallet provider
    account_number  VARCHAR(34)     NULL,   -- IBAN or local account number
    mobile_number   VARCHAR(20)     NULL,
    relationship    ENUM('family','friend','self','business','other') NOT NULL DEFAULT 'family',
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (beneficiary_id),
    KEY idx_beneficiary_customer (customer_id, is_active),
    KEY idx_beneficiary_country (country_code),
    KEY idx_beneficiary_currency (currency_code),
    CONSTRAINT fk_beneficiary_customer FOREIGN KEY (customer_id)   REFERENCES customers (customer_id),
    CONSTRAINT fk_beneficiary_country  FOREIGN KEY (country_code)  REFERENCES countries (country_code),
    CONSTRAINT fk_beneficiary_currency FOREIGN KEY (currency_code) REFERENCES currencies (currency_code),
    CONSTRAINT chk_beneficiary_bank   CHECK (payout_method <> 'bank_deposit'  OR (provider_name IS NOT NULL AND account_number IS NOT NULL)),
    CONSTRAINT chk_beneficiary_mobile CHECK (payout_method <> 'mobile_wallet' OR (provider_name IS NOT NULL AND mobile_number IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Money movement
-- -----------------------------------------------------------------------------

-- One row per business event. Which wallet columns are set depends on type:
--   deposit     dest_wallet_id                        (cash/card in)
--   withdrawal  source_wallet_id                      (cash out)
--   transfer    source_wallet_id, dest_wallet_id      (same currency, P2P)
--   remittance  source_wallet_id, beneficiary_id, fx  (cross-border payout)
--   reversal    reversal_of_txn_id                    (refund of a failed remittance)
-- Rows are append-only: triggers block DELETE and changes to the money columns.
CREATE TABLE transactions (
    txn_id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    txn_ref                 VARCHAR(20)     NOT NULL,   -- customer-facing reference
    idempotency_key         VARCHAR(64)     NULL,       -- client-supplied; makes retries safe
    txn_type                ENUM('deposit','withdrawal','transfer','remittance','reversal') NOT NULL,
    status                  ENUM('pending','completed','failed') NOT NULL,
    channel                 ENUM('app','web','branch','api') NOT NULL,
    source_wallet_id        BIGINT UNSIGNED NULL,
    dest_wallet_id          BIGINT UNSIGNED NULL,
    beneficiary_id          BIGINT UNSIGNED NULL,
    reversal_of_txn_id      BIGINT UNSIGNED NULL,
    amount                  DECIMAL(19,4)   NOT NULL,
    currency_code           CHAR(3)         NOT NULL,
    fee_amount              DECIMAL(19,4)   NOT NULL DEFAULT 0,
    fx_rate_id              BIGINT UNSIGNED NULL,
    payout_amount           DECIMAL(19,4)   NULL,
    payout_currency_code    CHAR(3)         NULL,
    failure_reason          VARCHAR(64)     NULL,
    created_at              DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    completed_at            DATETIME(6)     NULL,
    PRIMARY KEY (txn_id),
    UNIQUE KEY uq_txn_ref (txn_ref),
    UNIQUE KEY uq_txn_idempotency (idempotency_key),
    CONSTRAINT fk_txn_source_wallet   FOREIGN KEY (source_wallet_id)     REFERENCES wallets (wallet_id),
    CONSTRAINT fk_txn_dest_wallet     FOREIGN KEY (dest_wallet_id)       REFERENCES wallets (wallet_id),
    CONSTRAINT fk_txn_beneficiary     FOREIGN KEY (beneficiary_id)       REFERENCES beneficiaries (beneficiary_id),
    CONSTRAINT fk_txn_reversal_of     FOREIGN KEY (reversal_of_txn_id)   REFERENCES transactions (txn_id),
    CONSTRAINT fk_txn_currency        FOREIGN KEY (currency_code)        REFERENCES currencies (currency_code),
    CONSTRAINT fk_txn_fx_rate         FOREIGN KEY (fx_rate_id)           REFERENCES exchange_rates (rate_id),
    CONSTRAINT fk_txn_payout_currency FOREIGN KEY (payout_currency_code) REFERENCES currencies (currency_code),
    CONSTRAINT chk_txn_amount         CHECK (amount > 0 AND fee_amount >= 0),
    CONSTRAINT chk_txn_failed_reason  CHECK (status <> 'failed' OR failure_reason IS NOT NULL),
    CONSTRAINT chk_txn_shape CHECK (
        (txn_type = 'deposit'    AND dest_wallet_id   IS NOT NULL AND source_wallet_id IS NULL) OR
        (txn_type = 'withdrawal' AND source_wallet_id IS NOT NULL AND dest_wallet_id   IS NULL) OR
        (txn_type = 'transfer'   AND source_wallet_id IS NOT NULL AND dest_wallet_id   IS NOT NULL) OR
        (txn_type = 'remittance' AND source_wallet_id IS NOT NULL AND beneficiary_id   IS NOT NULL) OR
        (txn_type = 'reversal'   AND reversal_of_txn_id IS NOT NULL)
    )
    -- Indexes beyond PK/unique/FK are deliberately left out here: choosing
    -- them from real workload evidence is the performance-tuning phase.
    -- See docs/01-schema-design.md.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Double-entry ledger: the source of truth for balances.
-- wallets.balance is a cached running total; balance_after lets a statement
-- be produced without re-summing history.
CREATE TABLE ledger_entries (
    entry_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    txn_id          BIGINT UNSIGNED NOT NULL,
    wallet_id       BIGINT UNSIGNED NOT NULL,
    entry_type      ENUM('debit','credit') NOT NULL,
    amount          DECIMAL(19,4)   NOT NULL,
    balance_after   DECIMAL(19,4)   NOT NULL,
    created_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (entry_id),
    CONSTRAINT fk_ledger_txn    FOREIGN KEY (txn_id)    REFERENCES transactions (txn_id),
    CONSTRAINT fk_ledger_wallet FOREIGN KEY (wallet_id) REFERENCES wallets (wallet_id),
    CONSTRAINT chk_ledger_amount CHECK (amount > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Audit
-- -----------------------------------------------------------------------------

-- Written only by triggers (03_triggers.sql). db_user is the MySQL account
-- (USER()); app_user is the end user the application acts for, passed in by
-- the app with SET @app_user = '...'.
CREATE TABLE audit_log (
    audit_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    table_name      VARCHAR(64)     NOT NULL,
    record_id       BIGINT UNSIGNED NOT NULL,
    action          ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    old_row         JSON            NULL,
    new_row         JSON            NULL,
    db_user         VARCHAR(288)    NOT NULL,
    app_user        VARCHAR(64)     NULL,
    connection_id   BIGINT UNSIGNED NOT NULL,
    changed_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (audit_id),
    KEY idx_audit_record (table_name, record_id),
    KEY idx_audit_changed_at (changed_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
