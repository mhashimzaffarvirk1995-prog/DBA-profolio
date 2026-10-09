"""Verify stored event coverage and tamper detection without mutating live logs."""
import collections
import json
from pathlib import Path
import tempfile
import audit_collector as audit

seq, last = audit.check()
counts = collections.Counter()
allowed = {'seq','previous','collected_at','kind','timestamp','connection','command','operation','denied','hmac'}
first = None
for file in sorted(audit.OUT.glob('events-*.jsonl')):
    for line in file.read_text().splitlines():
        event = json.loads(line)
        assert set(event) <= allowed, 'unexpected audit field could expose SQL text'
        first = first or event
        counts[event.get('operation', 'OTHER')] += 1
        if event.get('denied'): counts['DENIED_CONNECT'] += 1
for operation in ['SELECT','CREATE','DROP','CALL','DENIED_CONNECT']:
    assert counts[operation] > 0, f'missing {operation} evidence'
print('PASS: SELECT, DDL, CALL and refused login recorded without SQL text or PII')
original_out, original_key = audit.OUT, audit.KEY
with tempfile.TemporaryDirectory() as scratch:
    audit.OUT = Path(scratch)
    file = audit.OUT / 'events-test.jsonl'
    file.write_text(json.dumps(first) + '\n')
    audit.check()
    first['operation'] = 'FORGED'
    file.write_text(json.dumps(first) + '\n')
    try:
        audit.check()
        raise AssertionError('forged event was accepted')
    except RuntimeError:
        print('PASS: forged audit event rejected by HMAC chain verification')
    audit.KEY = b'wrong-audit-key'
    try:
        audit.check()
        raise AssertionError('wrong audit key was accepted')
    except RuntimeError:
        print('PASS: incorrect audit verification key rejected')
audit.OUT, audit.KEY = original_out, original_key
print(f'PASS: {seq} live audit events authenticated; checkpoint {last}')
