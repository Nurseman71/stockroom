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

import base64
import hmac
import json
import os
import secrets
import sys
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

# When stdout is redirected to a file (as the LaunchAgent does, via
# StandardOutPath), Python fully buffers it instead of flushing per line.
# Since this process runs forever inside serve_forever(), that buffer
# would never flush on its own — reconfigure it up front so startup
# messages (including the sync token) actually land in the log file.
try:
    sys.stdout.reconfigure(line_buffering=True)
except AttributeError:
    pass  # older Python without reconfigure(); the flush=True calls below still cover it

PORT = int(os.environ.get("STOCKROOM_PORT", "8787"))
BASE_DIR = Path(__file__).resolve().parent
DATA_FILE = BASE_DIR / "stockroom_data.json"
INDEX_FILE = BASE_DIR / "index.html"
TOKEN_FILE = BASE_DIR / "stockroom_token.txt"
PHOTOS_DIR = BASE_DIR / "photos"
TOMBSTONE_MAX_AGE_DAYS = 30

PHOTOS_DIR.mkdir(exist_ok=True)

_lock = threading.Lock()


def get_sync_token():
    """
    Reads STOCKROOM_TOKEN from the environment if set (e.g. in the
    LaunchAgent plist) — otherwise generates one on first run and
    persists it to TOKEN_FILE (0600 permissions) so it survives restarts
    without needing manual setup. Either way, print it once at startup
    so it can be copied into the app's Settings panel.
    """
    env_token = os.environ.get("STOCKROOM_TOKEN", "").strip()
    if env_token:
        return env_token
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    token = secrets.token_hex(16)
    TOKEN_FILE.write_text(token, encoding="utf-8")
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass
    return token


SYNC_TOKEN = get_sync_token()


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


def prune_old_tombstones(items, max_age_days=TOMBSTONE_MAX_AGE_DAYS):
    """
    Deleted items are kept as tombstones (deleted: true) so the deletion
    can win future sync merges — but keeping them forever would grow the
    file without bound. Once a tombstone is older than max_age_days, any
    device that still disagreed has had ample time to sync, so it's safe
    to drop for good. Its photo file (if any) is cleaned up alongside it.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
    kept = []
    for item in items:
        if not item.get("deleted"):
            kept.append(item)
            continue
        raw_ts = item.get("updatedAt", "")
        try:
            ts = datetime.fromisoformat(raw_ts.replace("Z", "+00:00"))
        except ValueError:
            kept.append(item)  # unparsable timestamp: keep it, don't guess
            continue
        if ts >= cutoff:
            kept.append(item)
            continue
        # Old enough to prune — drop the item and any photo file it owned.
        photo_path = photo_path_for_id(item.get("id", ""))
        if photo_path is not None and photo_path.exists():
            try:
                photo_path.unlink()
            except OSError:
                pass
    return kept


def photo_path_for_id(item_id):
    """
    Deterministic filename (<id>.jpg) so the client never needs the server
    to tell it what a photo got saved as. Rejects anything that isn't a
    plain id (no path separators) so a crafted id can't escape PHOTOS_DIR.
    """
    if not item_id or "/" in item_id or "\\" in item_id or item_id in (".", ".."):
        return None
    return PHOTOS_DIR / f"{item_id}.jpg"


class Handler(BaseHTTPRequestHandler):
    def _parsed_path_and_token(self):
        """
        Token travels as a query param (?token=...), not a custom header —
        deliberately, to avoid the CORS "preflight" check a custom header
        would trigger, which iOS Safari has long-standing problems with.
        Same approach media_vault_server.py uses, for the same reason.
        """
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        token = query.get("token", [""])[0]
        return parsed.path, token

    def _token_ok(self, token):
        return hmac.compare_digest(token, SYNC_TOKEN)

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
        path, token = self._parsed_path_and_token()
        if path == "/api/data":
            if not self._token_ok(token):
                self._send_json(401, {"error": "Invalid or missing token"})
                return
            with _lock:
                data = load_data()
            self._send_json(200, data)
        elif path.startswith("/photos/"):
            if not self._token_ok(token):
                self._send_json(401, {"error": "Invalid or missing token"})
                return
            filename = path[len("/photos/"):]
            item_id = filename[:-4] if filename.endswith(".jpg") else filename
            photo_path = photo_path_for_id(item_id)
            if photo_path is None or not photo_path.exists():
                self.send_error(404, "Not found")
                return
            body = photo_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "public, max-age=86400")
            self.end_headers()
            self.wfile.write(body)
        elif path in ("/", "/index.html"):
            # The app shell itself stays open — only the data API is
            # gated. That matches how you'll actually use this: load the
            # page freely, but it needs the token to read or write boxes.
            self._send_file(INDEX_FILE, "text/html; charset=utf-8")
        else:
            self.send_error(404, "Not found")

    def do_POST(self):
        path, token = self._parsed_path_and_token()

        if path.startswith("/api/photos/"):
            if not self._token_ok(token):
                self._send_json(401, {"error": "Invalid or missing token"})
                return
            item_id = path[len("/api/photos/"):]
            photo_path = photo_path_for_id(item_id)
            if photo_path is None:
                self._send_json(400, {"error": "invalid id"})
                return
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                self._send_json(400, {"error": "invalid JSON"})
                return
            data_url = payload.get("data", "")
            # Expect a data URL like "data:image/jpeg;base64,....";
            # tolerate raw base64 too in case the client ever sends that.
            b64 = data_url.split(",", 1)[1] if "," in data_url else data_url
            try:
                photo_bytes = base64.b64decode(b64)
            except (ValueError, TypeError):
                self._send_json(400, {"error": "invalid photo data"})
                return
            tmp_path = photo_path.with_suffix(".tmp")
            with _lock:
                tmp_path.write_bytes(photo_bytes)
                tmp_path.replace(photo_path)
            self._send_json(200, {"filename": photo_path.name})
            return

        if path != "/api/data":
            self.send_error(404, "Not found")
            return
        if not self._token_ok(token):
            self._send_json(401, {"error": "Invalid or missing token"})
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
            merged_items = prune_old_tombstones(merged_items)
            merged = {"items": merged_items}
            save_data(merged)
        self._send_json(200, merged)

    def log_message(self, format, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Stockroom server running on http://0.0.0.0:{PORT}", flush=True)
    print(f"Data file: {DATA_FILE}", flush=True)
    print(f"Sync token: {SYNC_TOKEN}", flush=True)
    print("Paste that token into the app's Settings panel alongside the server URL.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
