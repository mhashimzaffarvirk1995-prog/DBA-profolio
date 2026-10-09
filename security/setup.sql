-- Public API only: internal helpers must never be granted to the application.
CREATE ROLE IF NOT EXISTS 'payflow_app_role', 'payflow_report_role', 'payflow_audit_role';
GRANT EXECUTE ON PROCEDURE payflow.sp_deposit TO 'payflow_app_role';
GRANT EXECUTE ON PROCEDURE payflow.sp_transfer_funds TO 'payflow_app_role';
GRANT EXECUTE ON PROCEDURE payflow.sp_send_remittance TO 'payflow_app_role';
GRANT EXECUTE ON PROCEDURE payflow.sp_complete_remittance TO 'payflow_app_role';
GRANT EXECUTE ON PROCEDURE payflow.sp_wallet_statement TO 'payflow_app_role';
CREATE OR REPLACE DEFINER='payflow_owner'@'localhost' SQL SECURITY DEFINER VIEW payflow.v_daily_totals AS
SELECT DATE(created_at) AS day, currency_code, status, COUNT(*) AS transactions,
       SUM(amount) AS amount
FROM payflow.transactions GROUP BY DATE(created_at), currency_code, status;
GRANT SELECT ON payflow.v_daily_totals TO 'payflow_report_role';
GRANT SELECT ON payflow.audit_log TO 'payflow_audit_role';
GRANT SELECT ON ops.backup_history TO 'payflow_audit_role';
CREATE USER IF NOT EXISTS 'payflow_app'@'%' IDENTIFIED BY '__APP_PASSWORD__' REQUIRE SSL;
CREATE USER IF NOT EXISTS 'payflow_report'@'%' IDENTIFIED BY '__REPORT_PASSWORD__' REQUIRE SSL;
CREATE USER IF NOT EXISTS 'payflow_auditor'@'%' IDENTIFIED BY '__AUDITOR_PASSWORD__' REQUIRE SSL;
ALTER USER 'payflow_app'@'%' REQUIRE SSL;
ALTER USER 'payflow_report'@'%' REQUIRE SSL;
ALTER USER 'payflow_auditor'@'%' REQUIRE SSL;
GRANT 'payflow_app_role' TO 'payflow_app'@'%';
GRANT 'payflow_report_role' TO 'payflow_report'@'%';
GRANT 'payflow_audit_role' TO 'payflow_auditor'@'%';
SET DEFAULT ROLE 'payflow_app_role' TO 'payflow_app'@'%';
SET DEFAULT ROLE 'payflow_report_role' TO 'payflow_report'@'%';
SET DEFAULT ROLE 'payflow_audit_role' TO 'payflow_auditor'@'%';
SET PERSIST require_secure_transport = ON;

-- Local portfolio benchmark tooling: readable synthetic production dataset,
-- payments through the public API; direct writes confined to payflow_test.
CREATE USER IF NOT EXISTS 'payflow_bench'@'%' IDENTIFIED BY '__BENCH_PASSWORD__' REQUIRE SSL;
ALTER USER 'payflow_bench'@'%' REQUIRE SSL;
GRANT 'payflow_app_role' TO 'payflow_bench'@'%';
SET DEFAULT ROLE 'payflow_app_role' TO 'payflow_bench'@'%';
GRANT SELECT ON payflow.* TO 'payflow_bench'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE ROUTINE, ALTER ROUTINE ON payflow_test.* TO 'payflow_bench'@'%';
