-- Synthetic legacy PostgreSQL database: signed sequences, enums, timestamptz,
-- NUMERIC, JSONB and native BOOLEAN. No production data is copied into this lab.
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
CREATE TYPE customer_state AS ENUM ('active','suspended','closed');
CREATE TYPE payment_kind AS ENUM ('deposit','transfer');
CREATE TABLE currencies(currency_code char(3) PRIMARY KEY,name varchar(64) NOT NULL,minor_units smallint NOT NULL);
CREATE TABLE countries(country_code char(2) PRIMARY KEY,name varchar(64) NOT NULL,currency_code char(3) REFERENCES currencies,dial_code varchar(6),is_send_market boolean,is_receive_market boolean);
CREATE TABLE customers(
 customer_id bigserial PRIMARY KEY,customer_ref varchar(16) UNIQUE NOT NULL,customer_type varchar(16) NOT NULL,
 first_name varchar(64) NOT NULL,last_name varchar(64) NOT NULL,email varchar(128) UNIQUE NOT NULL,phone varchar(20) NOT NULL,
 date_of_birth date,nationality_country_code char(2) REFERENCES countries,residence_country_code char(2) REFERENCES countries,
 national_id_number varchar(32),status customer_state NOT NULL,kyc_status varchar(16) NOT NULL,risk_rating varchar(8) NOT NULL,
 created_at timestamptz NOT NULL,updated_at timestamptz NOT NULL);
CREATE TABLE wallets(wallet_id bigserial PRIMARY KEY,customer_id bigint REFERENCES customers,currency_code char(3) REFERENCES currencies,
 wallet_type varchar(16) NOT NULL,balance numeric(19,4) NOT NULL,status varchar(16) NOT NULL,created_at timestamptz NOT NULL,updated_at timestamptz NOT NULL,
 UNIQUE(customer_id,currency_code,wallet_type));
CREATE TABLE transactions(txn_id bigserial PRIMARY KEY,txn_ref varchar(20) UNIQUE NOT NULL,idempotency_key varchar(64) UNIQUE,
 txn_type payment_kind NOT NULL,status varchar(16) NOT NULL,channel varchar(8) NOT NULL,
 source_wallet_id bigint REFERENCES wallets,dest_wallet_id bigint REFERENCES wallets,amount numeric(19,4) NOT NULL CHECK(amount>0),
 currency_code char(3) REFERENCES currencies,fee_amount numeric(19,4) NOT NULL,created_at timestamptz NOT NULL,completed_at timestamptz);
CREATE TABLE ledger_entries(entry_id bigserial PRIMARY KEY,txn_id bigint REFERENCES transactions,wallet_id bigint REFERENCES wallets,
 entry_type varchar(6) NOT NULL,amount numeric(19,4) NOT NULL,balance_after numeric(19,4) NOT NULL,created_at timestamptz NOT NULL);
CREATE INDEX ledger_wallet ON ledger_entries(wallet_id);
CREATE TABLE customer_preferences(customer_id bigint PRIMARY KEY REFERENCES customers,marketing_opt_in boolean NOT NULL,preferences jsonb NOT NULL);

SET TIME ZONE 'Asia/Karachi';
INSERT INTO currencies VALUES('GBP','Pound Sterling',2);
INSERT INTO countries VALUES('GB','United Kingdom','GBP','+44',true,false);
INSERT INTO customers VALUES(1,'PAYFLOW-HOUSE','system','PayFlow','House','house@migration.invalid','',NULL,'GB','GB',NULL,'active','verified','low','2026-01-01 05:00:00.123456+05','2026-01-01 05:00:00.123456+05');
INSERT INTO customers
SELECT 1000+g,'LEG'||lpad(g::text,10,'0'),'individual',
 CASE g%4 WHEN 0 THEN 'عائشہ' WHEN 1 THEN 'Zoë' WHEN 2 THEN '李' ELSE 'O''Brien' END,
 'Customer '||g,'legacy'||g||'@migration.invalid','+44'||lpad(g::text,10,'0'),
 CASE WHEN g%3=0 THEN NULL ELSE DATE '1990-01-01'+(g%365) END,'GB','GB',NULL,
 'active'::customer_state,'verified','low','2026-01-01 05:00:00.123456+05'::timestamptz,
 '2026-01-01 05:00:00.123456+05'::timestamptz FROM generate_series(1,20000) g;
INSERT INTO wallets VALUES(1,1,'GBP','settlement',-2000000,'active','2026-01-01 05:00:00.123456+05','2026-01-01 05:00:00.123456+05');
INSERT INTO wallets SELECT 1000+g,1000+g,'GBP','customer',100,'active','2026-01-01 05:00:00.123456+05'::timestamptz,'2026-01-01 05:00:00.123456+05'::timestamptz FROM generate_series(1,20000) g;
INSERT INTO transactions
SELECT g,'LDEP'||lpad(g::text,12,'0'),'legacy-deposit-'||g,'deposit'::payment_kind,'completed','api',NULL,1000+g,100,'GBP',0,
 '2026-01-01 00:00:00+00'::timestamptz+g*interval '1 microsecond','2026-01-01 00:00:00+00'::timestamptz+g*interval '1 microsecond' FROM generate_series(1,20000) g;
INSERT INTO ledger_entries SELECT 2*g-1,g,1,'debit',100,-100*g,'2026-01-01 00:00:00+00'::timestamptz+g*interval '1 microsecond' FROM generate_series(1,20000) g;
INSERT INTO ledger_entries SELECT 2*g,g,1000+g,'credit',100,100,'2026-01-01 00:00:00+00'::timestamptz+g*interval '1 microsecond' FROM generate_series(1,20000) g;
-- Ten transfer rounds. Each wallet sends/receives exactly 0.0123 in each round.
INSERT INTO transactions
SELECT 20000+g,'LTRF'||lpad(g::text,12,'0'),'legacy-transfer-'||g,'transfer'::payment_kind,'completed','api',
 1001+(g-1)%20000,1001+g%20000,0.0123,'GBP',0,
 '2026-02-01 00:00:00+00'::timestamptz+g*interval '1 microsecond','2026-02-01 00:00:00+00'::timestamptz+g*interval '1 microsecond' FROM generate_series(1,200000) g;
INSERT INTO ledger_entries
SELECT 40000+2*g-1,20000+g,1001+(g-1)%20000,'debit',0.0123,
 CASE WHEN (g-1)%20000=0 THEN 99.9877 ELSE 100 END,
 '2026-02-01 00:00:00+00'::timestamptz+g*interval '1 microsecond' FROM generate_series(1,200000) g;
INSERT INTO ledger_entries
SELECT 40000+2*g,20000+g,1001+g%20000,'credit',0.0123,
 CASE WHEN g%20000=0 THEN 100 ELSE 100.0123 END,
 '2026-02-01 00:00:00+00'::timestamptz+g*interval '1 microsecond' FROM generate_series(1,200000) g;
INSERT INTO customer_preferences SELECT customer_id,customer_id%2=0,
 jsonb_build_object('language',CASE customer_id%2 WHEN 0 THEN 'اردو' ELSE 'English' END,'notifications',jsonb_build_object('email',true,'sms',false),'tags',jsonb_build_array('migration',NULL,'💷'),'note',CASE WHEN customer_id%3=0 THEN NULL ELSE '' END)
 FROM customers WHERE customer_type='individual';
SELECT setval(pg_get_serial_sequence('customers','customer_id'),(SELECT max(customer_id) FROM customers));
SELECT setval(pg_get_serial_sequence('wallets','wallet_id'),(SELECT max(wallet_id) FROM wallets));
SELECT setval(pg_get_serial_sequence('transactions','txn_id'),(SELECT max(txn_id) FROM transactions));
SELECT setval(pg_get_serial_sequence('ledger_entries','entry_id'),(SELECT max(entry_id) FROM ledger_entries));
ANALYZE;
