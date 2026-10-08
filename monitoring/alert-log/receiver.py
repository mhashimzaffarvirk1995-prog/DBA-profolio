"""Minimal Alertmanager webhook receiver: one line per alert per notification."""
import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = "/log/alerts.log"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(LOG, "a") as f:
            for a in body.get("alerts", []):
                line = (f"{now} {a.get('status', '?').upper():8} {a['labels'].get('severity', '-'):8} "
                        f"{a['labels'].get('alertname')} {a['labels'].get('instance', a['labels'].get('type', ''))} "
                        f"- {a.get('annotations', {}).get('summary', '')}")
                print(line)
                f.write(line + "\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", 5001), Handler).serve_forever()
