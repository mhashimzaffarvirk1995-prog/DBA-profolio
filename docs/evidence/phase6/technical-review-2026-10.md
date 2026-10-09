# October 2026 technical access review

Review date: 2026-10-09 (UTC). Reviewer: **Codex, automated technical review**.
Scope: standalone PayFlow lab and its backup, audit and production monitoring
clients. This document is not human approval, a signed attestation or compliance certification.

Source: [current account/grant inventory](access-review-2026-10.md),
[access tests](access-tests.log), [real API tests](control-tests.log),
[audit tests](audit-tests.log) and [recovery evidence](encrypted-pitr.log).

| Reviewed control | Technical decision |
|---|---|
| Public application API | Retain five EXECUTE grants. Direct customer reads, wallet writes and helper execution are rejected. Customer ownership remains an application responsibility. |
| Reporting/auditor roles | Retain aggregate view and audit/history reads. No customer/KYC reads for reporting or audit mutation. |
| Definer | Retain locked payflow_owner with scoped table/column grants; routines, triggers and view use it. It has no login, DDL or grant authority. |
| Root | Retain local socket administration; root@% is locked and verified unable to authenticate over TCP. |
| Backup | Retain required backup/binlog privileges, payflow/ops reads and restricted performance_schema metadata. MySQL Shell 8.4 also needs two role metadata tables; mysql.user/password hashes are not granted. |
| Exporter | Retain performance_schema reads, table metadata and process/replication status. No global SELECT or application row reads. Production TLS verifies the CA and server name. |
| Benchmark | Retain for this synthetic portfolio dataset only; permitted direct writes are confined to payflow_test. Disable or replace before real personal data is loaded. |
| Encryption | Application, ops, test and mysql tablespaces encrypted; redo/undo/binlog flags on. Encrypted backup restore uses escrow keys rather than the live keyring. |
| Audit | Retain independent metadata-only collector, HMAC verification, acknowledged rotation and three health/buffer alerts. External immutable retention and identity correlation are deployment responsibilities. |
| Recovery custody | Private identity/escrow exports are ignored and restricted locally. An external protected copy and independent custodian are still required for host-loss DR. |

Verification: 46 SQL assertions pass; a scoped verified-TLS concurrency test
committed 80 transfers with zero deadlocks and reconciled balances. Six full-data
reconciliation checks have zero violations. Ciphertext tampering, truncation and
wrong identities are rejected. Encrypted full restore and PITR passed; the logical
backup wrote 35,219,646 rows and its encrypted inventory is authenticated.

The inventory deliberately retains failed historical backup outcomes. The initial
full-backup keyring configuration and restore staging/startup failures were fixed
and superseded by successful encrypted restore/PITR evidence. MySQL Shell's role
metadata discovery initially failed after SELECT was narrowed; the two required
tables were granted and the subsequent encrypted logical backup succeeded. A failed
attempt is not counted as a successful recovery.

Human owner/signature: **not supplied**. Before production use, an authorized
owner must approve the account register, appoint key/audit custodians, define
retention and off-host recovery, and record their own dated decisions. Repeat the
inventory and access tests monthly and after every account or privilege change.
