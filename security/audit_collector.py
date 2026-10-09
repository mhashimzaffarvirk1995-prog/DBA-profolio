"""Persist SQL operation metadata only; raw general-log text stays in tmpfs."""
import datetime as dt
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import re
import sys
import time
import threading

os.umask(0o077)
OUT = Path('/audit-events')
METRICS = {'seq': 0, 'last': 0}
SOURCE = Path('/run/audit/mysql.log')
KEY = bytes.fromhex(os.environ['AUDIT_HMAC_KEY'])
LINE = re.compile(r'^(\d{4}-\d\d-\d\dT\S+)\s+(\d+)\s+([^\t]+)\t(.*)$')

def digest(event):
    return hmac.new(KEY, json.dumps(event, sort_keys=True, separators=(',', ':')).encode(), hashlib.sha256).hexdigest()

def check():
    previous = '0' * 64
    seq = 0
    for file in sorted(OUT.glob('events-*.jsonl')):
        with file.open() as stream:
            for line in stream:
                event = json.loads(line)
                signature = event.pop('hmac')
                if event['previous'] != previous or event['seq'] != seq + 1 or not hmac.compare_digest(signature, digest(event)):
                    raise RuntimeError(f'audit chain invalid: {file.name}, sequence {seq + 1}')
                seq += 1
                previous = signature
    return seq, previous

def collect():
    OUT.mkdir(exist_ok=True)
    OUT.chmod(0o700)
    for file in OUT.iterdir():
        if file.is_file(): file.chmod(0o600)
    seq, previous = check()
    class Metrics(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            size = sum(p.stat().st_size for p in SOURCE.parent.glob('mysql.log*') if p.is_file())
            body = (f"payflow_audit_events_total {METRICS['seq']}\n"
                    f"payflow_audit_last_event_timestamp_seconds {METRICS['last']}\n"
                    f"payflow_audit_buffer_bytes {size}\n").encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('0.0.0.0', 9105), Metrics)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    current = None
    inode = None
    def emit(**fields):
        nonlocal seq, previous
        seq += 1
        now = dt.datetime.now(dt.timezone.utc)
        event = dict(seq=seq, previous=previous, collected_at=now.isoformat(), **fields)
        signature = digest(event)
        file = OUT / ('events-' + now.strftime('%Y-%m-%d') + '.jsonl')
        with file.open('a') as log:
            log.write(json.dumps(dict(event, hmac=signature), sort_keys=True) + '\n')
            log.flush()
            os.fsync(log.fileno())
        previous = signature
        METRICS.update(seq=seq, last=time.time())
    emit(kind='collector_start', operation='START')
    while True:
        if current is None:
            if not SOURCE.exists():
                time.sleep(.2)
                continue
            rotated = SOURCE.with_suffix('.log.rotated')
            candidate = SOURCE
            if rotated.exists():
                ack = OUT / f'ack-{rotated.stat().st_ino}'
                token_path = SOURCE.parent / 'rotation-token'
                token = token_path.read_text().strip() if token_path.exists() else f'legacy-{rotated.stat().st_ino}'
                if not ack.exists() or not ack.read_text().startswith(token + ' '):
                    candidate = rotated
            current = candidate.open(errors='replace')
            inode = os.fstat(current.fileno()).st_ino
            # Persisted cursor avoids replay after collector-only restart.
            cursor = OUT / 'cursor.json'
            if cursor.exists():
                state = json.loads(cursor.read_text())
                if state['inode'] == inode:
                    current.seek(state['offset'])
        position = current.tell()
        line = current.readline()
        if line and not line.endswith('\n'):
            current.seek(position)
            time.sleep(.1)
            continue
        if line:
            match = LINE.match(line.rstrip('\n'))
            if match:
                timestamp, connection, command, argument = match.groups()
                command = command.strip()
                operation = 'OTHER'
                if command == 'Query':
                    word = re.match(r'\s*([A-Za-z]+)', argument)
                    if word:
                        operation = word.group(1).upper()
                denied = command == 'Connect' and 'Access denied' in argument
                # No SQL, literal hashes, PII or credentials leave the RAM buffer.
                emit(kind='mysql_event', timestamp=timestamp, connection=int(connection),
                     command=command, operation=operation, denied=denied)
            cursor = OUT / 'cursor.json'
            temp = cursor.with_suffix('.tmp')
            temp.write_text(json.dumps(dict(inode=inode, offset=current.tell())))
            temp.replace(cursor)
            continue
        if SOURCE.exists() and SOURCE.stat().st_ino != inode:
            # FLUSH closed the old writer; EOF now acknowledges complete drain.
            token_path = SOURCE.parent / 'rotation-token'
            token = token_path.read_text().strip() if token_path.exists() else f'legacy-{inode}'
            (OUT / f'ack-{inode}').write_text(token + ' ' + previous + '\n')
            current.close()
            current = None
            continue
        time.sleep(.1)

if __name__ == '__main__':
    if sys.argv[1] == 'verify':
        seq, last = check()
        print(f'PASS: {seq} audit events authenticated; checkpoint {last}')
    else:
        collect()
