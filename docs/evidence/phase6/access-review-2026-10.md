# Access review — 2026-10-09T08:52:52.807019+00:00

Generated evidence; human approval is recorded separately.

## Accounts (no password hashes)

```text
User	Host	account_locked	password_expired	ssl_type
backup	%	N	N	ANY
exporter	%	N	N	ANY
mysql.infoschema	localhost	Y	N	
mysql.session	localhost	Y	N	
mysql.sys	localhost	Y	N	
payflow_app	%	N	N	ANY
payflow_app_role	%	Y	Y	
payflow_audit_role	%	Y	Y	
payflow_auditor	%	N	N	ANY
payflow_bench	%	N	N	ANY
payflow_owner	localhost	Y	N	
payflow_report	%	N	N	ANY
payflow_report_role	%	Y	Y	
root	%	Y	N	
root	localhost	N	N	
```

## Role memberships

```text
FROM_HOST	FROM_USER	TO_HOST	TO_USER	WITH_ADMIN_OPTION
%	payflow_app_role	%	payflow_app	N
%	payflow_audit_role	%	payflow_auditor	N
%	payflow_app_role	%	payflow_bench	N
%	payflow_report_role	%	payflow_report	N
```

## Default roles

```text
HOST	USER	DEFAULT_ROLE_HOST	DEFAULT_ROLE_USER
%	payflow_app	%	payflow_app_role
%	payflow_auditor	%	payflow_audit_role
%	payflow_bench	%	payflow_app_role
%	payflow_report	%	payflow_report_role
```

## Global grants

```text
GRANTEE	TABLE_CATALOG	PRIVILEGE_TYPE	IS_GRANTABLE
'backup'@'%'	def	BACKUP_ADMIN	NO
'backup'@'%'	def	LOCK TABLES	NO
'backup'@'%'	def	PROCESS	NO
'backup'@'%'	def	RELOAD	NO
'backup'@'%'	def	REPLICATION CLIENT	NO
'backup'@'%'	def	REPLICATION SLAVE	NO
'backup'@'%'	def	SHOW_ROUTINE	NO
'exporter'@'%'	def	PROCESS	NO
'exporter'@'%'	def	REPLICATION CLIENT	NO
'mysql.infoschema'@'localhost'	def	AUDIT_ABORT_EXEMPT	NO
'mysql.infoschema'@'localhost'	def	FIREWALL_EXEMPT	NO
'mysql.infoschema'@'localhost'	def	SELECT	NO
'mysql.infoschema'@'localhost'	def	SYSTEM_USER	NO
'mysql.session'@'localhost'	def	AUDIT_ABORT_EXEMPT	NO
'mysql.session'@'localhost'	def	AUTHENTICATION_POLICY_ADMIN	NO
'mysql.session'@'localhost'	def	BACKUP_ADMIN	NO
'mysql.session'@'localhost'	def	CLONE_ADMIN	NO
'mysql.session'@'localhost'	def	CONNECTION_ADMIN	NO
'mysql.session'@'localhost'	def	FIREWALL_EXEMPT	NO
'mysql.session'@'localhost'	def	PERSIST_RO_VARIABLES_ADMIN	NO
'mysql.session'@'localhost'	def	SESSION_VARIABLES_ADMIN	NO
'mysql.session'@'localhost'	def	SHUTDOWN	NO
'mysql.session'@'localhost'	def	SUPER	NO
'mysql.session'@'localhost'	def	SYSTEM_USER	NO
'mysql.session'@'localhost'	def	SYSTEM_VARIABLES_ADMIN	NO
'mysql.sys'@'localhost'	def	AUDIT_ABORT_EXEMPT	NO
'mysql.sys'@'localhost'	def	FIREWALL_EXEMPT	NO
'mysql.sys'@'localhost'	def	SYSTEM_USER	NO
'mysql.sys'@'localhost'	def	USAGE	NO
'payflow_app'@'%'	def	USAGE	NO
'payflow_app_role'@'%'	def	USAGE	NO
'payflow_auditor'@'%'	def	USAGE	NO
'payflow_audit_role'@'%'	def	USAGE	NO
'payflow_bench'@'%'	def	USAGE	NO
'payflow_owner'@'localhost'	def	USAGE	NO
'payflow_report'@'%'	def	USAGE	NO
'payflow_report_role'@'%'	def	USAGE	NO
'root'@'%'	def	ALLOW_NONEXISTENT_DEFINER	YES
'root'@'%'	def	ALTER	YES
'root'@'%'	def	ALTER ROUTINE	YES
'root'@'%'	def	APPLICATION_PASSWORD_ADMIN	YES
'root'@'%'	def	AUDIT_ABORT_EXEMPT	YES
'root'@'%'	def	AUDIT_ADMIN	YES
'root'@'%'	def	AUTHENTICATION_POLICY_ADMIN	YES
'root'@'%'	def	BACKUP_ADMIN	YES
'root'@'%'	def	BINLOG_ADMIN	YES
'root'@'%'	def	BINLOG_ENCRYPTION_ADMIN	YES
'root'@'%'	def	CLONE_ADMIN	YES
'root'@'%'	def	CONNECTION_ADMIN	YES
'root'@'%'	def	CREATE	YES
'root'@'%'	def	CREATE ROLE	YES
'root'@'%'	def	CREATE ROUTINE	YES
'root'@'%'	def	CREATE TABLESPACE	YES
'root'@'%'	def	CREATE TEMPORARY TABLES	YES
'root'@'%'	def	CREATE USER	YES
'root'@'%'	def	CREATE VIEW	YES
'root'@'%'	def	DELETE	YES
'root'@'%'	def	DROP	YES
'root'@'%'	def	DROP ROLE	YES
'root'@'%'	def	ENCRYPTION_KEY_ADMIN	YES
'root'@'%'	def	EVENT	YES
'root'@'%'	def	EXECUTE	YES
'root'@'%'	def	FILE	YES
'root'@'%'	def	FIREWALL_EXEMPT	YES
'root'@'%'	def	FLUSH_OPTIMIZER_COSTS	YES
'root'@'%'	def	FLUSH_PRIVILEGES	YES
'root'@'%'	def	FLUSH_STATUS	YES
'root'@'%'	def	FLUSH_TABLES	YES
'root'@'%'	def	FLUSH_USER_RESOURCES	YES
'root'@'%'	def	GROUP_REPLICATION_ADMIN	YES
'root'@'%'	def	GROUP_REPLICATION_STREAM	YES
'root'@'%'	def	INDEX	YES
'root'@'%'	def	INNODB_REDO_LOG_ARCHIVE	YES
'root'@'%'	def	INNODB_REDO_LOG_ENABLE	YES
'root'@'%'	def	INSERT	YES
'root'@'%'	def	LOCK TABLES	YES
'root'@'%'	def	OPTIMIZE_LOCAL_TABLE	YES
'root'@'%'	def	PASSWORDLESS_USER_ADMIN	YES
'root'@'%'	def	PERSIST_RO_VARIABLES_ADMIN	YES
'root'@'%'	def	PROCESS	YES
'root'@'%'	def	REFERENCES	YES
'root'@'%'	def	RELOAD	YES
'root'@'%'	def	REPLICATION CLIENT	YES
'root'@'%'	def	REPLICATION SLAVE	YES
'root'@'%'	def	REPLICATION_APPLIER	YES
'root'@'%'	def	REPLICATION_SLAVE_ADMIN	YES
'root'@'%'	def	RESOURCE_GROUP_ADMIN	YES
'root'@'%'	def	RESOURCE_GROUP_USER	YES
'root'@'%'	def	ROLE_ADMIN	YES
'root'@'%'	def	SELECT	YES
'root'@'%'	def	SENSITIVE_VARIABLES_OBSERVER	YES
'root'@'%'	def	SERVICE_CONNECTION_ADMIN	YES
'root'@'%'	def	SESSION_VARIABLES_ADMIN	YES
'root'@'%'	def	SET_ANY_DEFINER	YES
'root'@'%'	def	SHOW DATABASES	YES
'root'@'%'	def	SHOW VIEW	YES
'root'@'%'	def	SHOW_ROUTINE	YES
'root'@'%'	def	SHUTDOWN	YES
'root'@'%'	def	SUPER	YES
'root'@'%'	def	SYSTEM_USER	YES
'root'@'%'	def	SYSTEM_VARIABLES_ADMIN	YES
'root'@'%'	def	TABLE_ENCRYPTION_ADMIN	YES
'root'@'%'	def	TELEMETRY_LOG_ADMIN	YES
'root'@'%'	def	TRANSACTION_GTID_TAG	YES
'root'@'%'	def	TRIGGER	YES
'root'@'%'	def	UPDATE	YES
'root'@'%'	def	XA_RECOVER_ADMIN	YES
'root'@'localhost'	def	ALLOW_NONEXISTENT_DEFINER	YES
'root'@'localhost'	def	ALTER	YES
'root'@'localhost'	def	ALTER ROUTINE	YES
'root'@'localhost'	def	APPLICATION_PASSWORD_ADMIN	YES
'root'@'localhost'	def	AUDIT_ABORT_EXEMPT	YES
'root'@'localhost'	def	AUDIT_ADMIN	YES
'root'@'localhost'	def	AUTHENTICATION_POLICY_ADMIN	YES
'root'@'localhost'	def	BACKUP_ADMIN	YES
'root'@'localhost'	def	BINLOG_ADMIN	YES
'root'@'localhost'	def	BINLOG_ENCRYPTION_ADMIN	YES
'root'@'localhost'	def	CLONE_ADMIN	YES
'root'@'localhost'	def	CONNECTION_ADMIN	YES
'root'@'localhost'	def	CREATE	YES
'root'@'localhost'	def	CREATE ROLE	YES
'root'@'localhost'	def	CREATE ROUTINE	YES
'root'@'localhost'	def	CREATE TABLESPACE	YES
'root'@'localhost'	def	CREATE TEMPORARY TABLES	YES
'root'@'localhost'	def	CREATE USER	YES
'root'@'localhost'	def	CREATE VIEW	YES
'root'@'localhost'	def	DELETE	YES
'root'@'localhost'	def	DROP	YES
'root'@'localhost'	def	DROP ROLE	YES
'root'@'localhost'	def	ENCRYPTION_KEY_ADMIN	YES
'root'@'localhost'	def	EVENT	YES
'root'@'localhost'	def	EXECUTE	YES
'root'@'localhost'	def	FILE	YES
'root'@'localhost'	def	FIREWALL_EXEMPT	YES
'root'@'localhost'	def	FLUSH_OPTIMIZER_COSTS	YES
'root'@'localhost'	def	FLUSH_PRIVILEGES	YES
'root'@'localhost'	def	FLUSH_STATUS	YES
'root'@'localhost'	def	FLUSH_TABLES	YES
'root'@'localhost'	def	FLUSH_USER_RESOURCES	YES
'root'@'localhost'	def	GROUP_REPLICATION_ADMIN	YES
'root'@'localhost'	def	GROUP_REPLICATION_STREAM	YES
'root'@'localhost'	def	INDEX	YES
'root'@'localhost'	def	INNODB_REDO_LOG_ARCHIVE	YES
'root'@'localhost'	def	INNODB_REDO_LOG_ENABLE	YES
'root'@'localhost'	def	INSERT	YES
'root'@'localhost'	def	LOCK TABLES	YES
'root'@'localhost'	def	OPTIMIZE_LOCAL_TABLE	YES
'root'@'localhost'	def	PASSWORDLESS_USER_ADMIN	YES
'root'@'localhost'	def	PERSIST_RO_VARIABLES_ADMIN	YES
'root'@'localhost'	def	PROCESS	YES
'root'@'localhost'	def	REFERENCES	YES
'root'@'localhost'	def	RELOAD	YES
'root'@'localhost'	def	REPLICATION CLIENT	YES
'root'@'localhost'	def	REPLICATION SLAVE	YES
'root'@'localhost'	def	REPLICATION_APPLIER	YES
'root'@'localhost'	def	REPLICATION_SLAVE_ADMIN	YES
'root'@'localhost'	def	RESOURCE_GROUP_ADMIN	YES
'root'@'localhost'	def	RESOURCE_GROUP_USER	YES
'root'@'localhost'	def	ROLE_ADMIN	YES
'root'@'localhost'	def	SELECT	YES
'root'@'localhost'	def	SENSITIVE_VARIABLES_OBSERVER	YES
'root'@'localhost'	def	SERVICE_CONNECTION_ADMIN	YES
'root'@'localhost'	def	SESSION_VARIABLES_ADMIN	YES
'root'@'localhost'	def	SET_ANY_DEFINER	YES
'root'@'localhost'	def	SHOW DATABASES	YES
'root'@'localhost'	def	SHOW VIEW	YES
'root'@'localhost'	def	SHOW_ROUTINE	YES
'root'@'localhost'	def	SHUTDOWN	YES
'root'@'localhost'	def	SUPER	YES
'root'@'localhost'	def	SYSTEM_USER	YES
'root'@'localhost'	def	SYSTEM_VARIABLES_ADMIN	YES
'root'@'localhost'	def	TABLE_ENCRYPTION_ADMIN	YES
'root'@'localhost'	def	TELEMETRY_LOG_ADMIN	YES
'root'@'localhost'	def	TRANSACTION_GTID_TAG	YES
'root'@'localhost'	def	TRIGGER	YES
'root'@'localhost'	def	UPDATE	YES
'root'@'localhost'	def	XA_RECOVER_ADMIN	YES
```

## Dynamic grants

```text
USER	HOST	PRIV	WITH_GRANT_OPTION
backup	%	BACKUP_ADMIN	N
backup	%	SHOW_ROUTINE	N
mysql.infoschema	localhost	AUDIT_ABORT_EXEMPT	N
mysql.infoschema	localhost	FIREWALL_EXEMPT	N
mysql.infoschema	localhost	SYSTEM_USER	N
mysql.session	localhost	AUDIT_ABORT_EXEMPT	N
mysql.session	localhost	AUTHENTICATION_POLICY_ADMIN	N
mysql.session	localhost	BACKUP_ADMIN	N
mysql.session	localhost	CLONE_ADMIN	N
mysql.session	localhost	CONNECTION_ADMIN	N
mysql.session	localhost	FIREWALL_EXEMPT	N
mysql.session	localhost	PERSIST_RO_VARIABLES_ADMIN	N
mysql.session	localhost	SESSION_VARIABLES_ADMIN	N
mysql.session	localhost	SYSTEM_USER	N
mysql.session	localhost	SYSTEM_VARIABLES_ADMIN	N
mysql.sys	localhost	AUDIT_ABORT_EXEMPT	N
mysql.sys	localhost	FIREWALL_EXEMPT	N
mysql.sys	localhost	SYSTEM_USER	N
root	%	ALLOW_NONEXISTENT_DEFINER	Y
root	localhost	ALLOW_NONEXISTENT_DEFINER	Y
root	%	APPLICATION_PASSWORD_ADMIN	Y
root	localhost	APPLICATION_PASSWORD_ADMIN	Y
root	%	AUDIT_ABORT_EXEMPT	Y
root	localhost	AUDIT_ABORT_EXEMPT	Y
root	%	AUDIT_ADMIN	Y
root	localhost	AUDIT_ADMIN	Y
root	%	AUTHENTICATION_POLICY_ADMIN	Y
root	localhost	AUTHENTICATION_POLICY_ADMIN	Y
root	%	BACKUP_ADMIN	Y
root	localhost	BACKUP_ADMIN	Y
root	localhost	BINLOG_ADMIN	Y
root	%	BINLOG_ADMIN	Y
root	%	BINLOG_ENCRYPTION_ADMIN	Y
root	localhost	BINLOG_ENCRYPTION_ADMIN	Y
root	%	CLONE_ADMIN	Y
root	localhost	CLONE_ADMIN	Y
root	%	CONNECTION_ADMIN	Y
root	localhost	CONNECTION_ADMIN	Y
root	%	ENCRYPTION_KEY_ADMIN	Y
root	localhost	ENCRYPTION_KEY_ADMIN	Y
root	%	FIREWALL_EXEMPT	Y
root	localhost	FIREWALL_EXEMPT	Y
root	%	FLUSH_OPTIMIZER_COSTS	Y
root	localhost	FLUSH_OPTIMIZER_COSTS	Y
root	%	FLUSH_PRIVILEGES	Y
root	localhost	FLUSH_PRIVILEGES	Y
root	localhost	FLUSH_STATUS	Y
root	%	FLUSH_STATUS	Y
root	localhost	FLUSH_TABLES	Y
root	%	FLUSH_TABLES	Y
root	localhost	FLUSH_USER_RESOURCES	Y
root	%	FLUSH_USER_RESOURCES	Y
root	localhost	GROUP_REPLICATION_ADMIN	Y
root	%	GROUP_REPLICATION_ADMIN	Y
root	localhost	GROUP_REPLICATION_STREAM	Y
root	%	GROUP_REPLICATION_STREAM	Y
root	localhost	INNODB_REDO_LOG_ARCHIVE	Y
root	%	INNODB_REDO_LOG_ARCHIVE	Y
root	localhost	INNODB_REDO_LOG_ENABLE	Y
root	%	INNODB_REDO_LOG_ENABLE	Y
root	localhost	OPTIMIZE_LOCAL_TABLE	Y
root	%	OPTIMIZE_LOCAL_TABLE	Y
root	localhost	PASSWORDLESS_USER_ADMIN	Y
root	%	PASSWORDLESS_USER_ADMIN	Y
root	localhost	PERSIST_RO_VARIABLES_ADMIN	Y
root	%	PERSIST_RO_VARIABLES_ADMIN	Y
root	%	REPLICATION_APPLIER	Y
root	localhost	REPLICATION_APPLIER	Y
root	localhost	REPLICATION_SLAVE_ADMIN	Y
root	%	REPLICATION_SLAVE_ADMIN	Y
root	localhost	RESOURCE_GROUP_ADMIN	Y
root	%	RESOURCE_GROUP_ADMIN	Y
root	localhost	RESOURCE_GROUP_USER	Y
root	%	RESOURCE_GROUP_USER	Y
root	localhost	ROLE_ADMIN	Y
root	%	ROLE_ADMIN	Y
root	localhost	SENSITIVE_VARIABLES_OBSERVER	Y
root	%	SENSITIVE_VARIABLES_OBSERVER	Y
root	%	SERVICE_CONNECTION_ADMIN	Y
root	localhost	SERVICE_CONNECTION_ADMIN	Y
root	localhost	SESSION_VARIABLES_ADMIN	Y
root	%	SESSION_VARIABLES_ADMIN	Y
root	%	SET_ANY_DEFINER	Y
root	localhost	SET_ANY_DEFINER	Y
root	%	SHOW_ROUTINE	Y
root	localhost	SHOW_ROUTINE	Y
root	%	SYSTEM_USER	Y
root	localhost	SYSTEM_USER	Y
root	%	SYSTEM_VARIABLES_ADMIN	Y
root	localhost	SYSTEM_VARIABLES_ADMIN	Y
root	%	TABLE_ENCRYPTION_ADMIN	Y
root	localhost	TABLE_ENCRYPTION_ADMIN	Y
root	%	TELEMETRY_LOG_ADMIN	Y
root	localhost	TELEMETRY_LOG_ADMIN	Y
root	%	TRANSACTION_GTID_TAG	Y
root	localhost	TRANSACTION_GTID_TAG	Y
root	%	XA_RECOVER_ADMIN	Y
root	localhost	XA_RECOVER_ADMIN	Y
```

## Column grants

```text
GRANTEE	TABLE_CATALOG	TABLE_SCHEMA	TABLE_NAME	COLUMN_NAME	PRIVILEGE_TYPE	IS_GRANTABLE
'payflow_owner'@'localhost'	def	payflow	transactions	completed_at	UPDATE	NO
'payflow_owner'@'localhost'	def	payflow	transactions	failure_reason	UPDATE	NO
'payflow_owner'@'localhost'	def	payflow	transactions	status	UPDATE	NO
'payflow_owner'@'localhost'	def	payflow	wallets	balance	UPDATE	NO
'payflow_owner'@'localhost'	def	payflow	wallets	updated_at	UPDATE	NO
```

## Schema grants

```text
GRANTEE	TABLE_CATALOG	TABLE_SCHEMA	PRIVILEGE_TYPE	IS_GRANTABLE
'backup'@'%'	def	ops	EVENT	NO
'backup'@'%'	def	ops	SELECT	NO
'backup'@'%'	def	ops	SHOW VIEW	NO
'backup'@'%'	def	ops	TRIGGER	NO
'backup'@'%'	def	payflow	EVENT	NO
'backup'@'%'	def	payflow	SELECT	NO
'backup'@'%'	def	payflow	SHOW VIEW	NO
'backup'@'%'	def	payflow	TRIGGER	NO
'exporter'@'%'	def	ops	REFERENCES	NO
'exporter'@'%'	def	payflow	REFERENCES	NO
'exporter'@'%'	def	payflow	SHOW VIEW	NO
'exporter'@'%'	def	performance_schema	SELECT	NO
'mysql.session'@'localhost'	def	performance_schema	SELECT	NO
'mysql.sys'@'localhost'	def	sys	TRIGGER	NO
'payflow_bench'@'%'	def	payflow	SELECT	NO
'payflow_bench'@'%'	def	payflow_test	ALTER ROUTINE	NO
'payflow_bench'@'%'	def	payflow_test	CREATE ROUTINE	NO
'payflow_bench'@'%'	def	payflow_test	DELETE	NO
'payflow_bench'@'%'	def	payflow_test	EXECUTE	NO
'payflow_bench'@'%'	def	payflow_test	INSERT	NO
'payflow_bench'@'%'	def	payflow_test	SELECT	NO
'payflow_bench'@'%'	def	payflow_test	UPDATE	NO
'payflow_owner'@'localhost'	def	payflow	EXECUTE	NO
'payflow_owner'@'localhost'	def	payflow	SELECT	NO
'payflow_owner'@'localhost'	def	payflow	TRIGGER	NO
```

## Table grants

```text
GRANTEE	TABLE_CATALOG	TABLE_SCHEMA	TABLE_NAME	PRIVILEGE_TYPE	IS_GRANTABLE
'backup'@'%'	def	ops	backup_history	INSERT	NO
'backup'@'%'	def	mysql	default_roles	SELECT	NO
'backup'@'%'	def	performance_schema	keyring_component_status	SELECT	NO
'backup'@'%'	def	performance_schema	log_status	SELECT	NO
'backup'@'%'	def	performance_schema	replication_group_members	SELECT	NO
'backup'@'%'	def	mysql	role_edges	SELECT	NO
'mysql.session'@'localhost'	def	mysql	user	SELECT	NO
'mysql.sys'@'localhost'	def	sys	sys_config	SELECT	NO
'payflow_audit_role'@'%'	def	payflow	audit_log	SELECT	NO
'payflow_audit_role'@'%'	def	ops	backup_history	SELECT	NO
'payflow_owner'@'localhost'	def	payflow	audit_log	INSERT	NO
'payflow_owner'@'localhost'	def	payflow	ledger_entries	INSERT	NO
'payflow_owner'@'localhost'	def	payflow	transactions	INSERT	NO
'payflow_report_role'@'%'	def	payflow	v_daily_totals	SELECT	NO
```

## Routine grants

```text
Host	Db	User	Routine_name	Routine_type	Proc_priv
%	payflow	payflow_app_role	sp_complete_remittance	PROCEDURE	Execute
%	payflow	payflow_app_role	sp_deposit	PROCEDURE	Execute
%	payflow	payflow_app_role	sp_send_remittance	PROCEDURE	Execute
%	payflow	payflow_app_role	sp_transfer_funds	PROCEDURE	Execute
%	payflow	payflow_app_role	sp_wallet_statement	PROCEDURE	Execute
```

## Trigger definers

```text
TRIGGER_NAME	DEFINER
trg_customers_ai	payflow_owner@localhost
trg_customers_au	payflow_owner@localhost
trg_customers_ad	payflow_owner@localhost
trg_kyc_documents_ai	payflow_owner@localhost
trg_kyc_documents_au	payflow_owner@localhost
trg_beneficiaries_ai	payflow_owner@localhost
trg_beneficiaries_au	payflow_owner@localhost
trg_beneficiaries_ad	payflow_owner@localhost
trg_wallets_ai	payflow_owner@localhost
trg_wallets_au	payflow_owner@localhost
trg_wallets_bd	payflow_owner@localhost
trg_transactions_bu	payflow_owner@localhost
trg_transactions_au	payflow_owner@localhost
trg_transactions_bd	payflow_owner@localhost
trg_ledger_entries_bu	payflow_owner@localhost
trg_ledger_entries_bd	payflow_owner@localhost
trg_audit_log_bu	payflow_owner@localhost
trg_audit_log_bd	payflow_owner@localhost
```

## View definers

```text
TABLE_NAME	DEFINER
v_daily_totals	payflow_owner@localhost
```

## Definers

```text
ROUTINE_NAME	DEFINER	SECURITY_TYPE
sp_complete_remittance	payflow_owner@localhost	DEFINER
sp_deposit	payflow_owner@localhost	DEFINER
sp_lock_wallets	payflow_owner@localhost	DEFINER
sp_post_entry	payflow_owner@localhost	DEFINER
sp_send_remittance	payflow_owner@localhost	DEFINER
sp_transfer_funds	payflow_owner@localhost	DEFINER
sp_wallet_statement	payflow_owner@localhost	DEFINER
```

## Transport

```text
@@require_secure_transport	@@tls_version
1	TLSv1.2,TLSv1.3
Variable_name	Value
Ssl_cipher	TLS_AES_128_GCM_SHA256
```

## Encryption settings

```text
@@default_table_encryption	@@innodb_redo_log_encrypt	@@innodb_undo_log_encrypt	@@binlog_encryption
1	1	1	1
```

## Keyring component

```text
STATUS_KEY	STATUS_VALUE
Component_name	component_keyring_file
Author	Oracle Corporation
License	GPL
Implementation_name	component_keyring_file
Version	1.0
Component_status	Active
Data_file	/keyring/keys
Read_only	No
```

## Tablespace encryption

```text
NAME	ENCRYPTION
mysql	Y
ops/backup_history	Y
ops/phase6_pitr_probe	Y
payflow/audit_log	Y
payflow/beneficiaries	Y
payflow/countries	Y
payflow/currencies	Y
payflow/customers	Y
payflow/exchange_rates	Y
payflow/kyc_documents	Y
payflow/ledger_entries	Y
payflow/remittance_fees	Y
payflow/transactions	Y
payflow/wallets	Y
payflow_test/audit_log	Y
payflow_test/beneficiaries	Y
payflow_test/countries	Y
payflow_test/currencies	Y
payflow_test/customers	Y
payflow_test/exchange_rates	Y
payflow_test/kyc_documents	Y
payflow_test/ledger_entries	Y
payflow_test/remittance_fees	Y
payflow_test/transactions	Y
payflow_test/wallets	Y
```

## Backup outcomes this month UTC

```text
job	status	runs	latest
full	success	7	2026-10-09 07:46:59
logical	success	5	2026-10-09 08:43:55
verify	failed	7	2026-10-09 07:56:17
verify	success	5	2026-10-09 08:02:45
pitr_drill	success	4	2026-10-09 08:50:37
full	failed	1	2026-10-09 07:34:41
logical	failed	1	2026-10-09 08:40:26
```
