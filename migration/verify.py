#!/usr/bin/env python3
"""Independent final compatibility/security checks against the migrated lab."""
from decimal import Decimal
import json
import os
from pathlib import Path
import socket

import mysql.connector
import psycopg

import manage as lab


def rejects(label, operation, error, codes=None):
    try:
        operation()
    except error as exc:
        if codes is not None:
            assert getattr(exc, 'errno', None) in codes, label
        print('PASS: '+label)
    else:
        raise AssertionError(label+' unexpectedly accepted')


def routed_balance():
    """Tiny application adapter consumes the same durable cutover marker."""
    engine = json.loads(lab.STATE.read_text())['engine']
    if engine == 'postgres':
        with lab.pg('migration_writer') as conn:
            return conn.execute('SELECT balance FROM wallets WHERE wallet_id=1001').fetchone()[0]
    assert engine == 'mysql'
    conn = lab.my('migration_app','payflow')
    cur = conn.cursor()
    cur.execute("CALL sp_wallet_statement(1001,'2020-01-01','2030-01-01')")
    rows = cur.fetchall()
    while cur.nextset(): pass
    cur.close()
    conn.close()
    assert rows
    return rows[-1][6]


assert json.loads(lab.STATE.read_text())['engine']=='mysql'
try:
    lab.normal(2,'marketing_opt_in')
except ValueError:
    print('PASS: non-boolean target values cannot be hidden by checksum normalization')
else:
    raise AssertionError('invalid boolean accepted')
assert not Path('/repo/.env').exists() and not Path('/repo/.private').exists()
print('PASS: runner cannot read production credentials or private key directories')
assert routed_balance()==Decimal('100.0001')
print('PASS: routed application statement reads the preserved post-cutover payment')
assert lab.api_probe()==220001
print('PASS: retry after rollback and remigration retains the original transaction ID')

rejects('PostgreSQL plaintext rejected', lambda: psycopg.connect(host='postgres',dbname='legacy_payflow',user='migration_reader',password=os.environ['MIGRATION_READER_PASSWORD'],sslmode='disable',connect_timeout=5), psycopg.OperationalError)
rejects('PostgreSQL wrong server identity rejected', lambda: psycopg.connect(host='wrong-host',hostaddr=socket.gethostbyname('postgres'),dbname='legacy_payflow',user='migration_reader',password=os.environ['MIGRATION_READER_PASSWORD'],sslmode='verify-full',sslrootcert='/tls/ca.pem',connect_timeout=5), psycopg.OperationalError)
rejects('MySQL plaintext rejected', lambda: mysql.connector.connect(host='mysql',user='migration_app',password=os.environ['MIGRATION_APP_PASSWORD'],database='payflow',ssl_disabled=True,connection_timeout=5), mysql.connector.Error, {3159,1045})
rejects('MySQL wrong server identity rejected', lambda: mysql.connector.connect(host=socket.gethostbyname('mysql'),user='migration_app',password=os.environ['MIGRATION_APP_PASSWORD'],ssl_ca='/tls/ca.pem',ssl_verify_cert=True,ssl_verify_identity=True,connection_timeout=5), mysql.connector.Error, {2026})

conn=lab.my('migration_loader','payflow')
cur=conn.cursor()
rejects('orphan wallet rejected by retained foreign keys', lambda:cur.execute("INSERT INTO wallets(wallet_id,customer_id,currency_code) VALUES(999999,999999,'GBP')"),mysql.connector.Error,{1452})
rejects('malformed JSON rejected by native target type', lambda:cur.execute("UPDATE customer_preferences SET preferences='{' WHERE customer_id=1001"),mysql.connector.Error,{3140})
assert lab.one(conn,'SELECT COUNT(*) FROM transactions')[0]==220001
assert lab.one(conn,'SELECT COUNT(*) FROM ledger_entries')[0]==440002
assert lab.one(conn,'SELECT COUNT(*) FROM wallets WHERE wallet_id=999999')[0]==0
admin=lab.my(database='payflow')
assert lab.one(admin,"SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES WHERE NAME LIKE 'payflow/%' AND ENCRYPTION<>'Y'")[0]==0
admin.close()
assert lab.one(conn,'SELECT COUNT(*) FROM customers WHERE first_name IN (%s,%s,%s,%s)',('عائشہ','Zoë','李',"O'Brien"))[0] == 20000
assert lab.one(conn,'SELECT created_at FROM customers WHERE customer_id=1001')[0].isoformat(timespec='microseconds')=='2026-01-01T00:00:00.123456'
cur.close()
with lab.pg('migration_reader') as source:
    hashes=lab.compare(source,conn)
assert len(hashes)==7
lab.blocked_writer(timeout=False)
conn.close()
print('PASS: final seven-table hashes, Unicode, microsecond UTC, exact decimals, encrypted target and source fencing')
