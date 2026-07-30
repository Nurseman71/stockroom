#!/usr/bin/env python3
"""
storage_tracker_server.py

Small local sync server for the Stockroom storage tracker (index.html).
Mirrors the pattern used by media_vault_server.py: serves the static app,
persists a single JSON file to disk, and merges incoming syncs by
`updatedAt` instead of blind-overwriting so two devices can't stomp on
each other.

Run it directly:
    python3 storage_tracker_server.py

Then point the app's Settings > Server URL at this machine, e.g.
    http://localhost:8787
or, once exposed over Tailscale (same pattern as Media Vault):
    https://your-mac.tailnet-name.ts.net:8787

To run it persistently as a LaunchAgent, follow the same plist pattern
you already use for media_vault_server.py — same ProgramArguments style,
just pointed at this script and a port of your choosing.

No third-party dependencies. Standard library only.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

PORT = int(os.environ.get("STOCKROOM_PORT", "8787"))
BASE_DIR = Path(__file__).resolve().parent
DATA_FILE = BASE_DIR / "stockroom_data.json"
INDEX_FILE = BASE_DIR / "index.html"

_lock = threading.Lock()


def load_data():
    if not DATA_FILE.exists():
        return {"items": []}
    try:
        with DATA_FILE.open("r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"items": []}


def save_data(data):
    tmp = DATA_FILE.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    tmp.replace(DATA_FILE)


def merge_items(existing_items, incoming_items):
    """Newest updatedAt wins per id; never silently drops one side's edits."""
    by_id = {item["id"]: item for item in existing_items if "id" in item}
    for item in incoming_items:
        item_id = item.get("id")
        if not item_id:
            continue
        current = by_id.get(item_id)
        if current is None:
            by_id[item_id] = item
            continue
        current_ts = current.get("updatedAt", "")
        incoming_ts = item.get("updatedAt", "")
        if incoming_ts >= current_ts:
            by_id[item_id] = item
    return list(by_id.values())


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, content_type):
        if not path.exists():
            self.send_error(404, "Not found")
            return
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/data":
            with _lock:
                data = load_data()
            self._send_json(200, data)
        elif path in ("/", "/index.html"):
            self._send_file(INDEX_FILE, "text/html; charset=utf-8")
        else:
            self.send_error(404, "Not found")

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/data":
            self.send_error(404, "Not found")
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            incoming = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid JSON"})
            return

        incoming_items = incoming.get("items", [])
        with _lock:
            existing = load_data()
            merged_items = merge_items(existing.get("items", []), incoming_items)
            merged = {"items": merged_items}
            save_data(merged)
        self._send_json(200, merged)

    def log_message(self, format, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Stockroom server running on http://0.0.0.0:{PORT}")
    print(f"Data file: {DATA_FILE}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
