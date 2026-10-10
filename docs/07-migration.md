# Phase 7: PostgreSQL to MySQL migration

Status: **complete for the isolated technical lab**, validated 2026-10-10. This phase is a reproducible offline migration
rehearsal using a separately generated legacy PostgreSQL dataset and a dedicated
MySQL 8.4 target. Production PayFlow data, services and volumes are separate.

## Scope and source model

The PostgreSQL source contains 20,000 synthetic customers, a house account,
20,001 wallets, 20,000 opening deposits, 200,000 transfers, 440,000 ledger rows,
20,000 JSON preferences, and currency/country reference data. Seven populated
source tables map into the existing PayFlow MySQL schema plus
`customer_preferences`. Legacy transactions cover deposits and same-currency
transfers. FX, remittance, beneficiary and KYC tables exist empty in the target;
this rehearsal does not claim to migrate data absent from the legacy fixture.

| PostgreSQL representation | MySQL mapping and validation |
|---|---|
| BIGSERIAL / signed BIGINT | Explicit IDs into BIGINT UNSIGNED AUTO_INCREMENT; negative IDs rejected; next generated payment ID checked |
| NUMERIC(19,4) | DECIMAL(19,4), Python Decimal throughout; non-finite/excess-scale values rejected; no floating-point money |
| Native customer/payment enums | Existing PayFlow ENUMs; strict SQL mode and constraints retained |
| TIMESTAMPTZ | UTC-normalized DATETIME(6); offsets and all six microsecond digits preserved |
| BOOLEAN | BOOLEAN/TINYINT normalized to booleans for cross-engine checksums |
| JSONB | Native JSON; canonical sorted-key JSON comparison, with nulls, nested objects and Unicode |
| Case-sensitive source uniqueness | Probe actual target `utf8mb4_0900_ai_ci` email uniqueness before loading customers; demonstrate case-fold collision rejection |
| Foreign keys | Parent-first loading, with foreign keys/checks enabled throughout |

The seed includes Urdu, Chinese, accents, apostrophes, emoji, NULL birth dates,
empty strings and nonzero four-place transfer amounts. Identifiers and synthetic
email addresses use ASCII; the preflight is not an exhaustive collation audit of
arbitrary production data. Unsupported source values fail the run, rather than
being silently rounded or coerced.

## Consistent copy and fail-closed cutover

1. Generate the legacy fixtures on the isolated PostgreSQL server.
2. Acquire SHARE locks on every migrated source table. Existing application
   writers are blocked too; a real attempted write verifies the fence. Lock and
   statement timeouts bound failures.
3. Use a SELECT-only account in a verified REPEATABLE READ, READ ONLY snapshot.
   Both database clients verify the CA and server identity; plaintext connections
   are rejected.
4. Load parent-first in 2,000-row committed batches through a scoped target loader.
   A partial target is never a successful migration and is rebuilt on retry.
5. Stream every mapped column in primary-key order on both engines. Normalize
   UTC times, exact decimals, booleans and JSON; hash newline-separated canonical
   JSON rows with SHA-256. Both row count and digest must match for all seven tables.
6. Run the six PayFlow reconciliation checks and verify target encryption. Install
   the existing payment procedures/triggers with the locked scoped definer.
7. Revoke source application DML **before releasing the source freeze**, then
   atomically change the private routing marker to MySQL. The small verification
   adapter reads that marker to select its database backend.

The drill first corrupts a copied JSON preference deliberately. Validation must
refuse cutover and leave routing on PostgreSQL. It then rebuilds the isolated
target and completes a valid cutover. This is an offline migration: source writes
are unavailable for the entire copy/validation window. It is not zero-downtime CDC.

## Rollback after an acknowledged target write

After cutover, the scoped MySQL application executes a 0.0001 GBP deposit and
retries its idempotency key. Exactly one payment and two balanced ledger entries
must exist, using IDs beyond the migrated sequence range. The immutable ledger records
the balance change; a separate no-op lifecycle update exercises the retained audit
trigger. The application cannot update wallets directly.

The controlled rollback closes the probe client, revokes target API execution,
and copies the known post-cutover payment, ledger entries and affected wallet
balances back to PostgreSQL in a transaction. It advances PostgreSQL sequences,
compares all seven tables again, restores source write permission and switches
the marker back. A second full migration then preserves that payment on MySQL;
a routed statement and retry verify its amount and original ID.

The reverse path deliberately supports this one controlled deposit. It is not a
generic change stream or safe automatic rollback for unrestricted production
traffic. A real migration must inventory every possible target write, drain all
clients and provide durable reverse capture before permitting writes, or use a
forward-fix plan. The source remains fenced after the final successful cutover.

## Run and inspect

```bash
make migration-drill       # resets only isolated migration source/target fixtures
make migration-up          # retained final state; databases have no published ports
make migration-verify      # routed API, checksums, precision, TLS and FK/JSON negatives
make migration-down        # retain volumes, stop databases to free VM RAM
```

Docker, Python package/image downloads and the existing private lab CA are needed;
no cloud account is required. `make env` adds dedicated migration credentials to
ignored mode-600 `.env`. The runner never mounts a Docker socket or joins the
production/shared network. It mounts only migration code, canonical schema and the locked-owner SQL read-only,
with only the
evidence and private state folders writable. The MySQL target has separate data,
keyring and TLS volumes; source PostgreSQL is an isolated synthetic fixture whose
volume is not claimed to have at-rest encryption.

The lab root/superuser credentials exist solely for bootstrap, source fencing and
controlled reverse recovery on its private network. Bulk reads use a SELECT-only
source reader; loading uses a schema-scoped MySQL user; application access uses
public procedures only. No credential or private key is included in evidence.
A per-run route marker is stored under ignored `.private/migration/state`.

A host-side atomic directory lock prevents overlapping drill resets. If a host
crash leaves `.private/migration/run.lock`, inspect the processes before retiring
the stale lock; a rejected second run does not stop another run's services.

The runner stops both databases automatically after the drill to preserve memory
on the 4 GB VM. Retained migration volumes allow later inspection. Do not use
`docker compose down -v` if that retained state is needed.

## Evidence and measurements

| Measured check | Result |
|---|---|
| First validated cutover | 41.105 s |
| Post-write rollback, including full comparison | 14.598 s; acknowledged payments lost = 0 |
| Final validated cutover | 41.442 s |
| Final copied payments / ledger rows | 220,001 / 440,002 |
| Table verification | Seven row counts and canonical SHA-256 digests match |
| Reconciliation | All six invariants pass |
| Injected corruption | Cutover refused; source remains active |
| Transport/constraints | Plaintext, wrong host identity, orphan wallet and malformed JSON rejected |

The main drill records 56 passing assertions, followed by independent final
verification. Runtime versions were PostgreSQL 17.11, MySQL 8.4.11, Psycopg 3.3.6
and mysql-connector-python 9.7.0. The Python dependencies are pinned to those
validated versions.

Measured results are recorded in
[results.json](evidence/phase7/results.json),
[migration drill](evidence/phase7/migration-drill.log) and
[final verification](evidence/phase7/verification.log),
[isolation](evidence/phase7/isolation.json) and
[overlap rejection](evidence/phase7/exclusion-tests.log).
Initial failed attempts are retained separately and do not count as passing runs:
the PostgreSQL TLS inspection API was corrected; the reader-denial test moved
before source locking to avoid a blocked permission probe; encryption metadata
verification moved to the isolated administrator; and the audit assertion was
aligned with ledger-based deposit auditing. The final full drill and independent
verification both exited successfully.

The original 10M-row standalone dataset is not replaced or migrated by this lab.
Recorded duration is the synthetic offline copy/validation/cutover window, not a
forecast for a production PostgreSQL database or a physical application outage.

References: PostgreSQL [transaction isolation](https://www.postgresql.org/docs/17/transaction-iso.html),
[explicit locking](https://www.postgresql.org/docs/17/explicit-locking.html),
MySQL [data types](https://dev.mysql.com/doc/refman/8.4/en/data-types.html) and
[JSON](https://dev.mysql.com/doc/refman/8.4/en/json.html).
