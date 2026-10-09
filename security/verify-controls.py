#!/usr/bin/env python3
"""Meaningful phase 6 security checks using the live APIs and separate audit."""
import collections
import json
import pathlib
import subprocess
from manage import ROOT, run

secrets = dict(line.split('=', 1) for line in (ROOT / '.env').read_text().splitlines()
               if '=' in line and not line.startswith('#'))
# Real payment through the locked definer; a retry must not post a second time.
run("""USE payflow;
INSERT INTO customers (customer_ref,first_name,last_name,email,phone,nationality_country_code,residence_country_code,kyc_status)
SELECT 'SECURITY-PROBE','Security','Probe','security.probe@payflow.example','+440','GB','GB','verified'
WHERE NOT EXISTS (SELECT 1 FROM customers WHERE customer_ref='SECURITY-PROBE');
INSERT INTO wallets (customer_id,currency_code)
SELECT c.customer_id,'GBP' FROM customers c WHERE customer_ref='SECURITY-PROBE'
AND NOT EXISTS (SELECT 1 FROM wallets w WHERE w.customer_id=c.customer_id AND currency_code='GBP');
""")
wallet = run("SELECT wallet_id FROM payflow.wallets JOIN payflow.customers USING(customer_id) WHERE customer_ref='SECURITY-PROBE' AND currency_code='GBP'").stdout.splitlines()[-1]
call = f"CALL payflow.sp_deposit({int(wallet)},0.01,'api','phase6-locked-owner-probe',@t); SELECT @t;"
first = run(call, 'payflow_app', secrets['APP_PASSWORD']).stdout
second = run(call, 'payflow_app', secrets['APP_PASSWORD']).stdout
assert first == second, 'idempotent request returned different transaction'
count = run("SELECT COUNT(*) FROM payflow.transactions WHERE idempotency_key='phase6-locked-owner-probe'").stdout.splitlines()[-1]
assert count == '1', 'retry created duplicate payment'
print('PASS: real deposit works with locked definer; retry posts exactly once')
# The collector must record these classes and refused authentication without SQL.
run('SELECT 1;', 'payflow_report', secrets['REPORT_PASSWORD'])
run('SELECT 1;', 'payflow_report', 'wrong-password', ok=False)
run('CREATE TABLE IF NOT EXISTS ops.audit_ddl_probe (id INT) ENCRYPTION=\'Y\'; DROP TABLE ops.audit_ddl_probe;')
r = run('SELECT 1;', 'payflow_app', secrets['APP_PASSWORD'], host_override='payflow-mysql', ok=False)
assert r.returncode != 0 and 'ERROR 2026 ' in r.stderr, r.stderr
print('PASS: wrong server hostname rejected by VERIFY_IDENTITY')
# Independent collector retains events separately from the database server.
subprocess.run(['docker','exec','payflow-audit-collector','python','/app/audit_collector.py','verify'], check=True)
print('PASS: independent audit chain authentication')
