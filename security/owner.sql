-- No login and no DDL/grant/admin privileges; only the payment API's needs.
CREATE USER IF NOT EXISTS 'payflow_owner'@'localhost' ACCOUNT LOCK;
ALTER USER 'payflow_owner'@'localhost' ACCOUNT LOCK;
GRANT SELECT, TRIGGER ON payflow.* TO 'payflow_owner'@'localhost';
GRANT INSERT ON payflow.transactions TO 'payflow_owner'@'localhost';
GRANT INSERT ON payflow.ledger_entries TO 'payflow_owner'@'localhost';
GRANT INSERT ON payflow.audit_log TO 'payflow_owner'@'localhost';
GRANT UPDATE (balance, updated_at) ON payflow.wallets TO 'payflow_owner'@'localhost';
GRANT UPDATE (status, failure_reason, completed_at) ON payflow.transactions TO 'payflow_owner'@'localhost';
GRANT EXECUTE ON payflow.* TO 'payflow_owner'@'localhost';
