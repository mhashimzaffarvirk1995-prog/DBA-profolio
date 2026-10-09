# Phase 6: security and compliance

Status: **complete for the standalone technical lab**, validated 2026-10-09.
The 10M-row dataset, backup pipeline and recovery tooling now use encryption,
scoped accounts and identity-verified TLS. This is portfolio evidence, not a
regulatory certification or a substitute for human access approval.

## Access and transport

| Account | Permitted use |
|---|---|
| payflow_app | Execute five public payment/statement procedures only |
| payflow_report | Read the daily aggregate view, without customer identifiers |
| payflow_auditor | Read application audit rows and backup history |
| payflow_owner@localhost | Locked definer for payment routines, triggers and reporting; scoped table/column privileges; cannot log in |
| backup | Read payflow/ops and required performance_schema and role metadata; backup/replication privileges and insert backup evidence |
| exporter | Read performance_schema; process/replication status and table metadata; no application row reads |
| payflow_bench | Read synthetic payflow data, call public payment API; test writes confined to payflow_test |
| root@localhost | Local socket administration and recovery |
| root@% | Locked; remote root authentication is rejected |

All network service accounts require SSL. The server permits TLS 1.2/1.3 and
rejects plaintext TCP. Backup, binlog, benchmark, capacity and security clients
verify the lab CA and server name. The production exporter uses its separate
`client.production` authentication module with trusted CA and `tls-server-name=mysql`.
Replication/cluster labs keep their earlier configuration and are outside this rollout.

A real deposit through the locked definer and its idempotent retry passed.
Negative tests reject direct PII reads, wallet mutation, internal helper calls,
audit mutation, plaintext transport, wrong server names and remote root login.
The application still must authenticate customers and enforce wallet ownership:
database EXECUTE permission does not provide tenant isolation. The benchmark
account can read synthetic customer data and must not be used as an application account.

Evidence: [access tests](evidence/phase6/access-tests.log),
[API and identity checks](evidence/phase6/control-tests.log),
[46 SQL assertions](evidence/phase6/procedure-tests.log),
[concurrency regression](evidence/phase6/concurrency-tests.log).
The latter committed 80 transfers with zero deadlocks and conserved all money.

## Encryption and recoverable backups

All standalone payflow, ops and test InnoDB tables, plus the mysql system
tablespace, are encrypted. New tables default to encryption. Redo, undo and
server binlog encryption are enabled. Existing tables were rebuilt during a
maintenance window; the six full-data reconciliation checks then passed with
zero violations across 10,345,881 transactions and 23,576,467 ledger entries.
See [reconciliation](evidence/phase6/reconciliation.json).

The keyring component loads before InnoDB. Live keys, backup identity, public
recipient, encrypted escrow and recovered keys occupy separate Docker volumes.
Directories/files are restricted to 700/600 where appropriate. Every full backup
captures an encrypted keyring snapshot in escrow, prepares using the live keyring
and seals each file with authenticated age encryption. An encrypted SHA-256
inventory detects missing files and changed backup metadata. Retention removes
older full backups only after independent restore verification succeeds.

Logical dumps are compressed in a bounded RAM mount, encrypted and verified
before publication to persistent storage. Binlog streaming likewise receives
plaintext only in RAM and publishes encrypted snapshots atomically. Closed-log
acknowledgement prevents replaying an incomplete active snapshot. Historical
logical dumps and archives were sealed; obsolete plaintext server binlogs were
retired after successful encrypted PITR. Historical slow logs were encrypted and
round-trip verified before removing plaintext copies; slow logging is normally off.

Recovery decrypts the escrow snapshot into **a separate recovered keyring**;
it never mounts live keys into the recovery server. That recovered copy must be
writable because a recovery instance with a new UUID creates new encryption keys.
Physical restore preserves the empty prepared redo directory. The `latest`
symlink is resolved before traversing encrypted backup files. Verified recovery scratch is retired after shutdown; failed copies remain for inspection. Backup/restore jobs
share a lock; the multi-container PITR drill also excludes cron through a marker.

| Measured check | Result |
|---|---|
| Encrypted physical full backup | 9.1 GiB, 345 s |
| Independent full restore and data checks | 137 s; encrypted tables readable, currency balances zero |
| Encrypted full + escrowed keys + encrypted binlog PITR | Synthetic dropped table recovered with both pre/post-backup rows; checksum matches; RPO 0, 124 s |
| Ciphertext negative checks | Wrong identity, modified ciphertext and truncated ciphertext rejected |
| Logical backup | 35,219,646 rows; 1.06 GB compressed; 88 s including authenticated sealing |

Evidence: [full backup](evidence/phase6/encrypted-full-backup.log),
[restore](evidence/phase6/encrypted-restore.log),
[PITR](evidence/phase6/encrypted-pitr.log),
[logical backup](evidence/phase6/encrypted-logical-backup.log),
[crypto negative tests](evidence/phase6/backup-crypto-tests.log),
[logical inventory](evidence/phase6/logical-inventory-tests.log),
[PITR exclusion](evidence/phase6/pitr-exclusion-tests.log),
[legacy logs](evidence/phase6/legacy-log-protection.log).
The older Phase 3 timing describes the earlier unencrypted configuration.
PITR now drops only `ops.phase6_pitr_probe`, never a business table.

## Independent audit and review

Application triggers retain the before/after record of sensitive row changes.
A separate collector also observes general-log operations, including SELECT,
DDL, CALL and refused logins. Raw SQL stays in a 64 MiB RAM volume. Persistent
records contain operation/time/connection metadata, never SQL text, values or
credentials. Rotation every five minutes waits for a nonce/inode acknowledgement
from the collector before deleting the drained RAM file; interrupted rotation
can resume without dropping pending records.

The collector persists append-only JSON lines with sequence numbers and an
HMAC-SHA256 chain in a volume the database cannot access. Verification rejects
forged events and an incorrect verification key. It records connection IDs rather
than end-user identity, and SQL comments/multiline text are not a complete semantic
SQL audit. Application-supplied `@app_user` is not trusted identity evidence.

Three alerts cover collector availability, stale ingestion and RAM-buffer growth.
Prometheus validates all 13 alert rules, and production exporter scraping remains
healthy under the restricted TLS account. See [audit and monitoring tests](evidence/phase6/audit-tests.log).

The [monthly inventory](evidence/phase6/access-review-2026-10.md) includes accounts,
roles, global/dynamic/schema/table/column/routine grants, definers, encryption
and successful **and failed** backup outcomes. The separate
[technical review](evidence/phase6/technical-review-2026-10.md) records review
scope and decisions. It is explicitly an automated technical review, not a human
signature. A responsible owner should approve access each month, revoke unused
accounts and rerun verification.

## Reproduce and operate

For an existing standalone deployment with schema, ops and exporter accounts:

```bash
make env security-tls
make up ops-setup monitoring-setup ops-up
make security-setup             # locked definers, scoped users, remote root lock
make security-encrypt           # existing unencrypted tables only; maintenance window
make security-verify security-controls
make backup-full backup-verify
make pitr-drill
make backup-logical
make security-crypto-test security-audit-verify access-review
```

The one-time `security/rollout.sh` exits when an encrypted latest backup already
exists. Normal checks do not rebuild encrypted tables. Generated secrets remain
in ignored `.env`/`.private` files. MySQL Shell 8.4 additionally needs SELECT on `mysql.default_roles` and
`mysql.role_edges` for privilege discovery; it receives no access to password hashes.
Logical-backup credentials are supplied on stdin, not command-line arguments.
Setup preserves existing passwords and does
not automatically revoke unexpected pre-existing user grants; review the inventory.
Security hardening revokes the older backup/exporter global read grants and
reapplies their scopes. The standalone exporter setup also reapplies its restricted
grants on every run. Ops and the archiver receive no root credential.

Private recovery exports are in ignored `.private/recovery/`: the age identity
and encrypted keyring escrow. Keep a protected external copy, separate from
backups; losing the identity or snapshot makes recovery impossible. To recover
on another host, restore these into the backup-identity/key-escrow volumes and
restore the selected full backup and subsequent encrypted binlogs. Never print
private keys or commit these exports. A local export alone is not off-host DR.

Certificates have a one-year server lifetime. `make security-tls` checks validity
and refuses an imminently expired certificate; it does not silently rotate an
existing CA. For rotation, issue a replacement SAN certificate with the existing
private CA in a maintenance window, replace server files in `.private/tls/server`,
recreate security-init/MySQL to populate the TLS volume, then rerun identity checks
and exporter probes. CA replacement also requires distributing the new public
CA to every client before cutting over. Private CA material stays on the host.

## Lab boundaries

The file keyring, Docker data, private identity and audit verification key share
one host trust boundary. Host administrators can access them; a database
administrator can disable logging. A RAM buffer can lose uncollected events on
host failure. HMAC chaining detects modified records but deletion of an entire
trailing segment requires a separately retained checkpoint to detect. The tested
checkpoints in evidence anchor only the history up to their recorded sequence.
External immutable audit storage, retention policy, vault/HSM custody, independent
checkpoint anchoring and human approval are production deployment responsibilities.

MySQL documents file keyrings as unsuitable for regulatory key management:
[keyring component](https://dev.mysql.com/doc/refman/8.4/en/keyring-file-component.html),
[early loading](https://dev.mysql.com/doc/refman/8.4/en/keyring-component-installation.html),
[TLS configuration](https://dev.mysql.com/doc/refman/8.4/en/using-encrypted-connections.html).
