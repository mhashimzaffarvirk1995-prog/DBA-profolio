#!/usr/bin/env python3
"""Offline, fail-closed PostgreSQL -> isolated PayFlow MySQL migration drill."""
import argparse
import datetime as dt
from decimal import Decimal
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import time

import mysql.connector
import psycopg
from psycopg import sql

os.umask(0o077)
ROOT = Path('/repo')
OUT = Path('/evidence')
STATE = Path('/state/route.json')
TABLES = ['currencies', 'countries', 'customers', 'wallets', 'transactions', 'ledger_entries', 'customer_preferences']
KEYS = dict(zip(TABLES, ['currency_code', 'country_code', 'customer_id', 'wallet_id', 'txn_id', 'entry_id', 'customer_id']))
BOOLS = {'is_send_market', 'is_receive_market', 'marketing_opt_in'}
JSON_COLS = {'preferences'}
BATCH = 2000
RESULT = {'started_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'dataset': {'customers': 20000, 'transfers': 200000}, 'runs': [], 'checks': []}


def check(label, condition):
    if not condition:
        raise AssertionError(label)
    RESULT['checks'].append(label)
    print('PASS: ' + label, flush=True)


def pg(user='postgres', **kwargs):
    key = {'postgres': 'MIGRATION_PG_PASSWORD', 'migration_reader': 'MIGRATION_READER_PASSWORD', 'migration_writer': 'MIGRATION_WRITER_PASSWORD'}[user]
    conn = psycopg.connect(host='postgres', dbname='legacy_payflow', user=user, password=os.environ[key],
                           sslmode='verify-full', sslrootcert='/tls/ca.pem', connect_timeout=10,
                           options='-c statement_timeout=120000 -c lock_timeout=5000', **kwargs)
    conn.execute("SET TIME ZONE 'UTC'")
    return conn


def my(user='root', database=None):
    key = {'root': 'MIGRATION_MYSQL_PASSWORD', 'migration_loader': 'MIGRATION_LOADER_PASSWORD', 'migration_app': 'MIGRATION_APP_PASSWORD'}[user]
    conn = mysql.connector.connect(host='mysql', user=user, password=os.environ[key], database=database,
            ssl_ca='/tls/ca.pem', ssl_verify_cert=True, ssl_verify_identity=True, autocommit=True, connection_timeout=10)
    cur = conn.cursor()
    cur.execute("SET SESSION time_zone='+00:00'")
    cur.execute("SET SESSION sql_mode='STRICT_ALL_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'")
    cur.close()
    return conn


def route(engine, phase):
    STATE.parent.mkdir(exist_ok=True)
    temp = STATE.with_suffix('.tmp')
    temp.write_text(json.dumps({'engine': engine, 'phase': phase, 'updated_at': dt.datetime.now(dt.timezone.utc).isoformat()}))
    temp.replace(STATE)
    print(f'ROUTE: {engine} ({phase})')


def script(conn, text):
    """Execute repository SQL while respecting mysql-client DELIMITER blocks."""
    delimiter, lines = ';', []
    cur = conn.cursor()
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('--'):
            continue
        if line.startswith('DELIMITER '):
            delimiter = line.split()[1]
            continue
        lines.append(line)
        if line.rstrip().endswith(delimiter):
            statement = '\n'.join(lines).rstrip()[:-len(delimiter)]
            cur.execute(statement)
            while cur.nextset(): pass
            lines = []
    assert not lines, 'unterminated repository SQL'
    cur.close()


def seed():
    with pg(autocommit=True) as conn:
        conn.execute((ROOT / 'migration/source.sql').read_text(), prepare=False)
        for name, key in [('migration_reader', 'MIGRATION_READER_PASSWORD'), ('migration_writer', 'MIGRATION_WRITER_PASSWORD')]:
            if not conn.execute('SELECT 1 FROM pg_roles WHERE rolname=%s', (name,)).fetchone():
                conn.execute(sql.SQL('CREATE ROLE {} LOGIN PASSWORD {}').format(sql.Identifier(name), sql.Literal(os.environ[key])))
            conn.execute(sql.SQL('GRANT USAGE ON SCHEMA public TO {}').format(sql.Identifier(name)))
            conn.execute(sql.SQL('GRANT SELECT ON ALL TABLES IN SCHEMA public TO {}').format(sql.Identifier(name)))
        conn.execute('GRANT INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO migration_writer')
        conn.execute('GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO migration_writer')
        version = conn.execute('SELECT version()').fetchone()[0]
    route('postgres', 'legacy-ready')
    RESULT['source_version'] = version
    print('Seeded 20,000 synthetic customers, 220,000 payments and 440,000 ledger entries')
    # Test actual denial before acquiring SHARE locks: even an unauthorized
    # UPDATE can wait for its table lock before PostgreSQL checks privileges.
    try:
        with pg('migration_reader', autocommit=True) as reader:
            reader.execute('UPDATE wallets SET balance=balance WHERE wallet_id=1001')
    except psycopg.errors.InsufficientPrivilege: check('source reader cannot write', True)
    else: raise AssertionError('reader has write access')


def bootstrap():
    # This hostname is only resolvable on the dedicated Compose network. No
    # production network, port, socket or data volume is available to this runner.
    conn = my()
    cur = conn.cursor()
    cur.execute('DROP DATABASE IF EXISTS payflow')
    cur.execute("CREATE DATABASE payflow CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci DEFAULT ENCRYPTION='Y'")
    cur.execute('USE payflow')
    script(conn, (ROOT / 'schema/01_tables.sql').read_text())
    cur.execute('CREATE TABLE customer_preferences (customer_id BIGINT UNSIGNED PRIMARY KEY, marketing_opt_in BOOLEAN NOT NULL, preferences JSON NOT NULL, FOREIGN KEY(customer_id) REFERENCES customers(customer_id)) ENGINE=InnoDB')
    for user, key in [('migration_loader','MIGRATION_LOADER_PASSWORD'), ('migration_app','MIGRATION_APP_PASSWORD')]:
        cur.execute(f'CREATE USER IF NOT EXISTS `{user}`@\'%\' IDENTIFIED BY %s REQUIRE SSL', (os.environ[key],))
    cur.execute("GRANT SELECT,INSERT,UPDATE,DELETE ON payflow.* TO 'migration_loader'@'%'")
    cur.execute("GRANT CREATE TEMPORARY TABLES ON payflow.* TO 'migration_loader'@'%'")
    RESULT['target_version'], RESULT['target_uuid'] = one(conn, 'SELECT VERSION(),@@server_uuid')
    cur.close()
    conn.close()


def one(conn, query, args=None):
    cur = conn.cursor()
    cur.execute(query, args)
    row = cur.fetchone()
    cur.close()
    return row


def columns(conn, table):
    return [row[0] for row in conn.execute('SELECT column_name FROM information_schema.columns WHERE table_schema=\'public\' AND table_name=%s ORDER BY ordinal_position', (table,))]


def normal(value, column):
    if value is None: return None
    if column in BOOLS:
        if value not in (True, False, 0, 1):
            raise ValueError('invalid boolean representation')
        return bool(value)
    if column in JSON_COLS: return json.loads(value) if isinstance(value, str) else value
    if isinstance(value, Decimal):
        if not value.is_finite() or value != value.quantize(Decimal('.0001')):
            raise ValueError('non-finite or excess-scale money')
        return format(value.quantize(Decimal('.0001')), 'f')
    if isinstance(value, dt.datetime):
        if value.tzinfo: value = value.astimezone(dt.timezone.utc).replace(tzinfo=None)
        if not 1000 <= value.year <= 9999: raise ValueError('timestamp out of MySQL range')
        return value.isoformat(timespec='microseconds')
    if isinstance(value, dt.date): return value.isoformat()
    return value


def adapt(row, names):
    out = []
    for name, value in zip(names, row):
        if name in JSON_COLS: value = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        elif isinstance(value, dt.datetime) and value.tzinfo: value = value.astimezone(dt.timezone.utc).replace(tzinfo=None)
        if isinstance(value, Decimal): normal(value, name)
        if value is not None and (name.endswith('_id') or name == 'customer_id') and isinstance(value, int):
            if not 0 <= value <= 18446744073709551615: raise ValueError('signed ID cannot map to unsigned ID')
        out.append(value)
    return tuple(out)


def source_rows(conn, table, names):
    cur = conn.cursor(name='scan_' + table)
    cur.itersize = BATCH
    cur.execute(sql.SQL('SELECT {} FROM {} ORDER BY {}').format(sql.SQL(',').join(map(sql.Identifier, names)), sql.Identifier(table), sql.Identifier(KEYS[table])))
    return cur


def fingerprint(rows, names):
    digest, count = hashlib.sha256(), 0
    for row in rows:
        values = [normal(value, col) for col, value in zip(names, row)]
        digest.update(json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf8') + b'\n')
        count += 1
    return {'rows': count, 'sha256': digest.hexdigest()}


def compare(source, target):
    results = {}
    for table in TABLES:
        names = columns(source, table)
        with source_rows(source, table, names) as rows: src = fingerprint(rows, names)
        cur = target.cursor()
        cur.execute('SELECT ' + ','.join('`'+c+'`' for c in names) + f' FROM `{table}` ORDER BY `{KEYS[table]}`')
        dst = fingerprint(cur, names)
        cur.close()
        if src != dst: raise ValueError(f'row-count/checksum mismatch: {table}')
        results[table] = {'source': src, 'target': dst}
        print(f'VALIDATED: {table}: {src["rows"]:,} rows, SHA256 {src["sha256"]}')
    return results


def reconcile(target):
    queries = {
        'currency nets to zero': 'SELECT COUNT(*) FROM (SELECT currency_code FROM wallets GROUP BY currency_code HAVING SUM(balance)<>0) q',
        'no negative customer balance': "SELECT COUNT(*) FROM wallets WHERE wallet_type='customer' AND balance<0",
        'wallet equals ledger': "SELECT COUNT(*) FROM wallets w LEFT JOIN (SELECT wallet_id,SUM(IF(entry_type='credit',amount,-amount)) net FROM ledger_entries GROUP BY wallet_id) l USING(wallet_id) WHERE w.balance<>COALESCE(l.net,0)",
        'every transaction balanced': "SELECT COUNT(*) FROM (SELECT txn_id FROM ledger_entries GROUP BY txn_id HAVING SUM(IF(entry_type='credit',amount,-amount))<>0) q",
        'completed payments have ledger': "SELECT COUNT(*) FROM transactions t WHERE status='completed' AND NOT EXISTS(SELECT 1 FROM ledger_entries l WHERE l.txn_id=t.txn_id)",
        'no missing reversal': "SELECT COUNT(*) FROM transactions t WHERE txn_type='remittance' AND status='failed' AND NOT EXISTS(SELECT 1 FROM transactions r WHERE r.reversal_of_txn_id=t.txn_id)",
    }
    for label, query in queries.items(): check(label, one(target, query)[0] == 0)


def install_api():
    conn = my(database='payflow')
    script(conn, (ROOT/'security/owner.sql').read_text())
    for file, kind in [('02_procedures.sql','PROCEDURE'), ('03_triggers.sql','TRIGGER')]:
        text = (ROOT/'schema'/file).read_text().replace('CREATE '+kind, "CREATE DEFINER='payflow_owner'@'localhost' "+kind)
        script(conn, text)
    cur = conn.cursor()
    for routine in ['sp_deposit','sp_transfer_funds','sp_send_remittance','sp_complete_remittance','sp_wallet_statement']:
        cur.execute(f"GRANT EXECUTE ON PROCEDURE payflow.{routine} TO 'migration_app'@'%'")
    cur.close()
    conn.close()


def permissions(conn, enable):
    verb = 'GRANT INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO' if enable else 'REVOKE INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public FROM'
    conn.execute(verb+' migration_writer')


def blocked_writer(timeout=True):
    try:
        with pg('migration_writer', autocommit=True) as writer:
            writer.execute("SET lock_timeout='300ms'")
            writer.execute('UPDATE wallets SET balance=balance WHERE wallet_id=1001')
    except psycopg.Error as exc:
        expected = '55P03' if timeout else '42501'
        check('source write rejected by '+('freeze lock' if timeout else 'revoked write permissions'), exc.sqlstate == expected)
    else: raise AssertionError('source writer was not fenced')


def preflight(source, target):
    check('source uses verified TLS', source.execute('SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()').fetchone()[0])
    check('target uses verified TLS', bool(one(target, "SHOW SESSION STATUS LIKE 'Ssl_cipher'")[1]))
    # Probe the actual target collation before loading any customer data.
    cur = target.cursor()
    cur.execute('CREATE TEMPORARY TABLE email_preflight(email VARCHAR(128) COLLATE utf8mb4_0900_ai_ci UNIQUE)')
    cur.executemany('INSERT INTO email_preflight VALUES(%s)', [(r[0],) for r in source.execute('SELECT email FROM customers')])
    cur.execute("INSERT INTO email_preflight VALUES('CaseProbe@migration.invalid')")
    try: cur.execute("INSERT INTO email_preflight VALUES('caseprobe@migration.invalid')")
    except mysql.connector.IntegrityError: check('case-folding uniqueness conflict detected', True)
    else: raise AssertionError('collation preflight failed')
    cur.execute('DROP TEMPORARY TABLE email_preflight')
    cur.close()
    for value in [Decimal('NaN'), Decimal('0.00001')]:
        try: normal(value, 'amount')
        except ValueError: check('invalid money rejected: '+str(value), True)
        else: raise AssertionError('unsafe money accepted')
    try: adapt((-1,), ['wallet_id'])
    except ValueError: check('negative signed ID rejected', True)
    else: raise AssertionError('unsafe signed ID accepted')


def migrate(label, inject=False):
    started = time.monotonic()
    bootstrap()
    route('postgres', 'preparing-'+label)
    gate = pg(autocommit=False)
    source = target = None
    switched = False
    try:
        # SHARE conflicts with INSERT/UPDATE/DELETE locks, including already
        # connected writers. Bound lock acquisition instead of hanging forever.
        gate.execute("SET lock_timeout='5s'")
        gate.execute('LOCK TABLE '+','.join(TABLES)+' IN SHARE MODE')
        blocked_writer()
        source = pg('migration_reader', autocommit=False)
        source.commit()
        source.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
        source.read_only = True
        check('source snapshot is repeatable-read and read-only',
              source.execute('SHOW transaction_isolation').fetchone()[0] == 'repeatable read'
              and source.execute('SHOW transaction_read_only').fetchone()[0] == 'on')
        target = my('migration_loader', 'payflow')
        preflight(source, target)
        for table in TABLES:
            names = columns(source, table)
            insert = 'INSERT INTO `'+table+'` ('+','.join('`'+c+'`' for c in names)+') VALUES ('+','.join(['%s']*len(names))+')'
            with source_rows(source, table, names) as rows:
                cur = target.cursor()
                count = 0
                while batch := rows.fetchmany(BATCH):
                    target.start_transaction()
                    cur.executemany(insert, [adapt(row,names) for row in batch])
                    target.commit()
                    count += len(batch)
                cur.close()
            print(f'LOADED: {table}: {count:,}')
        if inject:
            cur = target.cursor()
            cur.execute("UPDATE customer_preferences SET preferences=JSON_SET(preferences,'$.injected',true) WHERE customer_id=1001")
            cur.close()
        hashes = compare(source, target)
        reconcile(target)
        admin = my(database='payflow')
        try:
            check('all target tables encrypted', one(admin,"SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES WHERE NAME LIKE 'payflow/%' AND ENCRYPTION<>'Y'")[0] == 0)
        finally: admin.close()
        install_api()
        # Revoke before releasing the source lock; no gap for a stale writer.
        with pg(autocommit=True) as admin: permissions(admin, False)
        route('mysql', 'validated-'+label)
        switched = True
        seconds = round(time.monotonic()-started,3)
        RESULT['runs'].append({'label':label,'duration_s':seconds,'tables':hashes})
        print(f'CUTOVER: {label} in {seconds}s; all seven tables identical')
    finally:
        if source: source.close()
        if target: target.close()
        gate.rollback()
        gate.close()
        if not switched: route('postgres', 'validation-rejected-'+label)
    blocked_writer(timeout=False)


def api_probe():
    app = my('migration_app', 'payflow')
    cur = app.cursor()
    for _ in range(2):
        cur.execute("CALL sp_deposit(1001,0.0001,'api','phase7-post-cutover',@id)")
        while cur.nextset(): pass
    cur.execute('SELECT @id')
    txn = cur.fetchone()[0]
    app.close()
    admin = my(database='payflow')
    check('new target ID follows migrated sequence', txn > 220000)
    check('post-cutover retry is idempotent', one(admin,"SELECT COUNT(*) FROM transactions WHERE idempotency_key='phase7-post-cutover'")[0] == 1)
    check('post-cutover exact four-place amount', one(admin,'SELECT amount FROM transactions WHERE txn_id=%s',(txn,))[0] == Decimal('.0001'))
    check('payment has exactly two immutable ledger records', one(admin,'SELECT COUNT(*) FROM ledger_entries WHERE txn_id=%s',(txn,))[0] == 2)
    # Deposits are audited through their immutable ledger, not audit_log.
    # Exercise the retained lifecycle audit trigger without changing data.
    audit_cur = admin.cursor()
    audit_cur.execute('UPDATE transactions SET completed_at=completed_at WHERE txn_id=%s',(txn,))
    audit_cur.close()
    check('locked definer lifecycle audit trigger retained', one(admin,'SELECT COUNT(*) FROM audit_log')[0] > 0)
    restricted = my('migration_app','payflow')
    try:
        cur = restricted.cursor()
        cur.execute('UPDATE wallets SET balance=0 WHERE wallet_id=1001')
    except mysql.connector.Error as exc: check('application cannot bypass payment procedures', exc.errno == 1142)
    else: raise AssertionError('application can write wallets')
    finally: restricted.close()
    reconcile(admin)
    admin.close()
    return txn


def rollback(txn):
    started = time.monotonic()
    route('mysql', 'rollback-write-fence')
    # Drain the probe connection before revoking. This drill has exactly one
    # controlled post-cutover payment; it is not a generic CDC implementation.
    target = my(database='payflow')
    cur = target.cursor()
    for routine in ['sp_deposit','sp_transfer_funds','sp_send_remittance','sp_complete_remittance','sp_wallet_statement']:
        cur.execute(f"REVOKE EXECUTE ON PROCEDURE payflow.{routine} FROM 'migration_app'@'%'")
    cur.close()
    with pg(autocommit=False) as dest:
        dest.execute('LOCK TABLE '+','.join(TABLES)+' IN SHARE ROW EXCLUSIVE MODE')
        for table, condition in [('transactions','txn_id>220000'), ('ledger_entries','txn_id>220000')]:
            names = columns(dest, table)
            cur = target.cursor()
            cur.execute('SELECT '+','.join('`'+c+'`' for c in names)+' FROM '+table+' WHERE '+condition+' ORDER BY '+KEYS[table])
            rows = list(cur)
            cur.close()
            for row in rows:
                values = [normal(v,c) if isinstance(v,dt.datetime) else v for v,c in zip(row,names)]
                dest.execute(sql.SQL('INSERT INTO {} ({}) VALUES ({})').format(sql.Identifier(table), sql.SQL(',').join(map(sql.Identifier,names)), sql.SQL(',').join([sql.Placeholder()]*len(names))),values)
        cur = target.cursor()
        cur.execute('SELECT wallet_id,balance,updated_at FROM wallets WHERE wallet_id IN (1,1001)')
        for wallet_id,balance,updated in cur:
            dest.execute('UPDATE wallets SET balance=%s,updated_at=%s WHERE wallet_id=%s',(balance,updated.replace(tzinfo=dt.timezone.utc),wallet_id))
        cur.close()
        for table,key in [('transactions','txn_id'),('ledger_entries','entry_id')]:
            dest.execute(sql.SQL("SELECT setval(pg_get_serial_sequence({},{}),(SELECT MAX({}) FROM {}))").format(sql.Literal(table),sql.Literal(key),sql.Identifier(key),sql.Identifier(table)))
    with pg('migration_reader') as source:
        hashes = compare(source,target)
        check('rollback preserves acknowledged target payment', source.execute('SELECT COUNT(*) FROM transactions WHERE txn_id=%s AND amount=.0001',(txn,)).fetchone()[0]==1)
    with pg(autocommit=True) as admin: permissions(admin,True)
    route('postgres','rollback-validated')
    target.close()
    RESULT['rollback']={'duration_s':round(time.monotonic()-started,3),'acknowledged_payments_lost':0,'tables':hashes}
    print(f'ROLLBACK: {RESULT["rollback"]["duration_s"]}s; acknowledged payments lost=0')


def all_steps():
    seed()
    try: migrate('injected-mismatch',inject=True)
    except ValueError as exc:
        check('checksum mismatch blocks cutover', 'checksum mismatch' in str(exc) and json.loads(STATE.read_text())['engine']=='postgres')
    else: raise AssertionError('mismatch allowed cutover')
    migrate('first-cutover')
    txn = api_probe()
    rollback(txn)
    migrate('final-cutover')
    check('final route points to MySQL', json.loads(STATE.read_text())['engine']=='mysql')
    RESULT['dependencies']={p:importlib.metadata.version(p) for p in ['psycopg','mysql-connector-python']}
    RESULT['finished_at']=dt.datetime.now(dt.timezone.utc).isoformat()
    RESULT['status']='passed'
    (OUT/'results.json').write_text(json.dumps(RESULT,ensure_ascii=False,indent=2)+'\n')
    print('PASS: Phase 7 end-to-end migration, rejection gate, cutover and post-write rollback')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['all','seed'])
    args=parser.parse_args()
    OUT.mkdir(exist_ok=True)
    if args.action=='all': all_steps()
    else: seed()
