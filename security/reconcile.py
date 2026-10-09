#!/usr/bin/env python3
"""Fail the phase gate on any nonzero financial invariant violation."""
import datetime as dt
import json
import time
from manage import ROOT, run

checks = [
 ('currency_balance', "SELECT COUNT(*) FROM (SELECT currency_code FROM payflow.wallets GROUP BY currency_code HAVING SUM(balance)<>0) x"),
 ('negative_customer_wallet', "SELECT COUNT(*) FROM payflow.wallets WHERE wallet_type='customer' AND balance<0"),
 ('wallet_ledger_mismatch', "SELECT COUNT(*) FROM payflow.wallets w LEFT JOIN (SELECT wallet_id,SUM(IF(entry_type='credit',amount,-amount)) net FROM payflow.ledger_entries GROUP BY wallet_id) l ON l.wallet_id=w.wallet_id WHERE w.balance<>COALESCE(l.net,0)"),
 ('unbalanced_transactions', "SELECT COUNT(*) FROM (SELECT txn_id FROM payflow.ledger_entries GROUP BY txn_id HAVING SUM(IF(entry_type='debit',amount,-amount))<>0) x"),
 ('missing_ledger', "SELECT COUNT(*) FROM payflow.transactions t WHERE (t.status='completed' OR t.txn_type='remittance') AND NOT EXISTS (SELECT 1 FROM payflow.ledger_entries le WHERE le.txn_id=t.txn_id)"),
 ('unrefunded_failure', "SELECT COUNT(*) FROM payflow.transactions t WHERE t.txn_type='remittance' AND t.status='failed' AND NOT EXISTS (SELECT 1 FROM payflow.transactions r WHERE r.reversal_of_txn_id=t.txn_id)"),
]
result = dict(timestamp=dt.datetime.now(dt.timezone.utc).isoformat(), checks=[])
for name, sql in checks:
    start = time.monotonic()
    violations = int(run(sql).stdout.splitlines()[-1])
    result['checks'].append(dict(name=name, violations=violations, seconds=round(time.monotonic()-start, 2)))
    (ROOT / 'docs/evidence/phase6/reconciliation.json').write_text(json.dumps(result, indent=2) + '\n')
    if violations:
        raise RuntimeError(f'{name}: {violations} financial invariant violations')
    print('PASS: ' + name, flush=True)
result['counts'] = {}
for table in ['transactions','ledger_entries','customers']:
    result['counts'][table] = int(run(f'SELECT COUNT(*) FROM payflow.{table}').stdout.splitlines()[-1])
result['status'] = 'passed'
(ROOT / 'docs/evidence/phase6/reconciliation.json').write_text(json.dumps(result, indent=2) + '\n')
