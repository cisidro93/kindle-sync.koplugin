#!/usr/bin/env python3
"""Cross-device reading sync server for kindle-sync.koplugin.

A single-file, dependency-free (Python 3.8+ standard library only) server that
keeps reading progress in sync between Kindle, Boox and any other device that
runs KOReader.

* Speaks the KOReader "Progress sync" (kosync) protocol, so KOReader's
  built-in Progress sync plugin can use it directly on any device.
* Adds a few small extensions that the kindle-sync plugin uses:
    - ``book_key``: a format-independent book identity (title + author), so a
      Kindle KFX book converted to EPUB and the EPUB on a Boox are recognised as
      the same book even though their file hashes differ.
    - ``base_version``: optimistic concurrency, so a device that read offline
      cannot silently overwrite progress made on another device.
    - Pairing codes: add a device by typing a 6 character code instead of a
      username and password.
* Ships a small web dashboard (``/``) that shows each book's progress on every
  device, lists paired devices, and creates pairing codes.

Run it:

    python3 kindle_sync_server.py --port 8081 --data ./sync-data

The first start prints a generated dashboard password unless one is given with
``--admin-password`` or the ``KSYNC_ADMIN_PASSWORD`` environment variable.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

SERVER_VERSION = "1.0.0"
OWNER = "reader"
PAIR_CODE_TTL = 15 * 60
PAIR_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I confusion
SESSION_TTL = 30 * 24 * 3600
MAX_BODY = 64 * 1024
MAX_FAILURES = 10  # failed sign-ins / pairing codes per client before a lockout
LOCKOUT_SECONDS = 15 * 60

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    userkey TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT NOT NULL,
    username TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    device_key TEXT,
    created_at INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    PRIMARY KEY (username, device_id)
);
CREATE TABLE IF NOT EXISTS progress (
    username TEXT NOT NULL,
    book_key TEXT NOT NULL,
    document TEXT NOT NULL,
    progress TEXT NOT NULL,
    percentage REAL NOT NULL,
    device TEXT NOT NULL DEFAULT '',
    device_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    authors TEXT NOT NULL DEFAULT '',
    timestamp INTEGER NOT NULL,
    version INTEGER NOT NULL,
    position TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (username, book_key)
);
CREATE TABLE IF NOT EXISTS device_progress (
    username TEXT NOT NULL,
    book_key TEXT NOT NULL,
    device_id TEXT NOT NULL,
    device TEXT NOT NULL DEFAULT '',
    percentage REAL NOT NULL,
    timestamp INTEGER NOT NULL,
    PRIMARY KEY (username, book_key, device_id)
);
CREATE TABLE IF NOT EXISTS aliases (
    username TEXT NOT NULL,
    document TEXT NOT NULL,
    book_key TEXT NOT NULL,
    PRIMARY KEY (username, document)
);
CREATE TABLE IF NOT EXISTS pair_codes (
    code TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);
"""


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, extra: dict | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.extra = extra or {}


def _hash_password(password: str, salt: str | None = None) -> str:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 200_000).hex()
    return f"{salt}${digest}"


def _check_password(password: str, stored: str) -> bool:
    try:
        salt, _ = stored.split("$", 1)
    except ValueError:
        return False
    return hmac.compare_digest(_hash_password(password, salt), stored)


_SPACE = "[ \t\n\v\f\r]"
_ASCII_PUNCT_OR_CTRL = re.compile(r"[!-/:-@\[-`{-~\x00-\x1f\x7f]")
# Typographic dashes/quotes (U+2013..U+201D), ellipsis and no-break space, so
# "Ender’s Game" from the Kindle store matches "Ender's Game" from an EPUB.
_TYPOGRAPHIC = re.compile("[\u2013-\u201d\u2026\u00a0]")


def _ascii_lower(text: str) -> str:
    return text.translate({c: c + 32 for c in range(65, 91)})


def normalize_text(text) -> str:
    """Python twin of CloudSyncPolicy.normalize (lua/lib/cloud_sync_policy.lua).

    Both sides must produce identical keys, so this mirrors the Lua patterns:
    ASCII-only lowercase, typographic quotes/dashes to spaces, bracketed parts dropped, one leading article dropped
    in the order the, a, an, ASCII punctuation/control chars to spaces.
    """
    s = _TYPOGRAPHIC.sub(" ", _ascii_lower(str(text or "")))
    for pattern in (r"\([^()]*\)", r"\[[^\[\]]*\]"):
        previous = None
        while previous != s:
            previous, s = s, re.sub(pattern, " ", s)
    for article in ("the", "a", "an"):
        s = re.sub(rf"^{_SPACE}*{article}{_SPACE}+", "", s, count=1)
    s = _ASCII_PUNCT_OR_CTRL.sub(" ", s)
    s = re.sub(rf"{_SPACE}+", " ", s)
    return re.sub(rf"^{_SPACE}+|{_SPACE}+$", "", s)


def first_author(authors) -> str:
    match = re.match(r"[^\n;&]+", str(authors or ""))
    first = match.group(0) if match else ""
    parts = re.match(rf"^{_SPACE}*([^,]+),{_SPACE}*(.+)$", first)
    if parts:
        first = parts.group(2) + " " + parts.group(1)
    return normalize_text(first)


def book_key_for(title, authors, fallback=None) -> str | None:
    """Python twin of CloudSyncPolicy.bookKey: format-independent book identity."""
    t = normalize_text(title)
    if not t:
        t = normalize_text(re.sub(r"\.[^./]+$", "", str(fallback or "")))
        return f"file:{t}" if t else None
    a = first_author(authors)
    return f"{t}|{a}" if a else t


def _clean(value, limit: int = 256) -> str:
    if value is None:
        return ""
    return str(value).strip()[:limit]


class Throttle:
    """Counts failed sign-ins per client and locks the client out for a while.

    Stops password, device-key and pairing-code guessing once the server is
    reachable from the internet. Successful requests are never counted.
    """

    def __init__(self, max_failures: int = MAX_FAILURES, window: int = LOCKOUT_SECONDS):
        self.max_failures = max_failures
        self.window = window
        self.lock = threading.Lock()
        self.failures: dict[str, list[float]] = {}

    def _recent(self, client: str, now: float) -> list[float]:
        recent = [t for t in self.failures.get(client, []) if now - t < self.window]
        if recent:
            self.failures[client] = recent
        else:
            self.failures.pop(client, None)
        return recent

    def blocked(self, client: str) -> bool:
        with self.lock:
            return len(self._recent(client, time.time())) >= self.max_failures

    def fail(self, client: str) -> None:
        now = time.time()
        with self.lock:
            self._recent(client, now)
            self.failures.setdefault(client, []).append(now)
            if len(self.failures) > 10000:  # bound memory under a wide attack
                self.failures.pop(next(iter(self.failures)))


class Store:
    """SQLite-backed state. One connection per call keeps threads independent."""

    def __init__(self, path: str):
        self.path = path
        self.lock = threading.Lock()
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")  # readers never wait for a writer
            db.executescript(SCHEMA)
            columns = {r["name"] for r in db.execute("PRAGMA table_info(progress)")}
            if "position" not in columns:  # databases created by v1.0.0
                db.execute("ALTER TABLE progress ADD COLUMN position TEXT NOT NULL DEFAULT ''")

    @contextlib.contextmanager
    def connect(self):
        """Opens a connection, commits on success, and always closes it."""
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    # -- settings ---------------------------------------------------------
    def get_setting(self, key: str) -> str | None:
        with self.connect() as db:
            row = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
            return row["value"] if row else None

    def set_setting(self, key: str, value: str) -> None:
        with self.lock, self.connect() as db:
            db.execute("INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)", (key, value))

    # -- accounts ---------------------------------------------------------
    def ensure_owner(self) -> None:
        with self.lock, self.connect() as db:
            if not db.execute("SELECT 1 FROM users WHERE username=?", (OWNER,)).fetchone():
                db.execute(
                    "INSERT INTO users(username, userkey, created_at) VALUES(?, ?, ?)",
                    (OWNER, secrets.token_hex(16), int(time.time())),
                )

    def create_user(self, username: str, userkey: str) -> bool:
        with self.lock, self.connect() as db:
            if db.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone():
                return False
            db.execute(
                "INSERT INTO users(username, userkey, created_at) VALUES(?, ?, ?)",
                (username, userkey, int(time.time())),
            )
            return True

    def set_userkey(self, username: str, userkey: str) -> None:
        with self.lock, self.connect() as db:
            db.execute("UPDATE users SET userkey=? WHERE username=?", (userkey, username))

    def authenticate(self, username: str, key: str) -> bool:
        if not username or not key:
            return False
        with self.connect() as db:
            row = db.execute("SELECT userkey FROM users WHERE username=?", (username,)).fetchone()
            if row and hmac.compare_digest(row["userkey"], key):
                return True
            rows = db.execute(
                "SELECT device_key FROM devices WHERE username=? AND device_key IS NOT NULL", (username,)
            ).fetchall()
            return any(hmac.compare_digest(r["device_key"], key) for r in rows)

    # -- devices ----------------------------------------------------------
    def touch_device(self, username: str, device_id: str, name: str = "", model: str = "") -> None:
        if not device_id:
            return
        now = int(time.time())
        with self.lock, self.connect() as db:
            row = db.execute(
                "SELECT name, model FROM devices WHERE username=? AND device_id=?", (username, device_id)
            ).fetchone()
            if row:
                db.execute(
                    "UPDATE devices SET last_seen=?, name=?, model=? WHERE username=? AND device_id=?",
                    (now, name or row["name"], model or row["model"], username, device_id),
                )
            else:
                db.execute(
                    "INSERT INTO devices(device_id, username, name, model, created_at, last_seen) VALUES(?,?,?,?,?,?)",
                    (device_id, username, name, model, now, now),
                )

    def list_devices(self, username: str) -> list[dict]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT device_id, name, model, created_at, last_seen, device_key IS NOT NULL AS paired "
                "FROM devices WHERE username=? ORDER BY last_seen DESC",
                (username,),
            ).fetchall()
            return [dict(r) for r in rows]

    def remove_device(self, username: str, device_id: str) -> None:
        with self.lock, self.connect() as db:
            db.execute("DELETE FROM devices WHERE username=? AND device_id=?", (username, device_id))
            db.execute("DELETE FROM device_progress WHERE username=? AND device_id=?", (username, device_id))

    # -- pairing ----------------------------------------------------------
    def create_pair_code(self, username: str) -> tuple[str, int]:
        now = int(time.time())
        code = "".join(secrets.choice(PAIR_CODE_ALPHABET) for _ in range(6))
        expires = now + PAIR_CODE_TTL
        with self.lock, self.connect() as db:
            db.execute("DELETE FROM pair_codes WHERE expires_at < ?", (now,))
            db.execute("INSERT OR REPLACE INTO pair_codes(code, username, expires_at) VALUES(?,?,?)", (code, username, expires))
        return code, expires

    def active_pair_codes(self, username: str) -> list[dict]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT code, expires_at FROM pair_codes WHERE username=? AND expires_at>=? ORDER BY expires_at DESC",
                (username, int(time.time())),
            ).fetchall()
            return [dict(r) for r in rows]

    def claim_pair_code(self, code: str, device_id: str, name: str, model: str) -> tuple[str, str]:
        code = re.sub(r"[^A-Z0-9]", "", code.upper())
        now = int(time.time())
        with self.lock, self.connect() as db:
            row = db.execute("SELECT username, expires_at FROM pair_codes WHERE code=?", (code,)).fetchone()
            if not row or row["expires_at"] < now:
                raise ApiError(HTTPStatus.NOT_FOUND, "pair_code_invalid", "That pairing code is wrong or has expired.")
            db.execute("DELETE FROM pair_codes WHERE code=?", (code,))
            username = row["username"]
            device_key = secrets.token_hex(16)
            db.execute(
                "INSERT INTO devices(device_id, username, name, model, device_key, created_at, last_seen) "
                "VALUES(?,?,?,?,?,?,?) ON CONFLICT(username, device_id) DO UPDATE SET "
                "name=excluded.name, model=excluded.model, device_key=excluded.device_key, last_seen=excluded.last_seen",
                (device_id, username, name, model, device_key, now, now),
            )
            return username, device_key

    # -- progress ---------------------------------------------------------
    def resolve_book_key(self, db: sqlite3.Connection, username: str, document: str) -> str:
        row = db.execute("SELECT book_key FROM aliases WHERE username=? AND document=?", (username, document)).fetchone()
        return row["book_key"] if row else document

    def get_progress(self, username: str, document: str) -> dict | None:
        """Looks a book up by file hash or book key.

        When a file hash resolves to progress saved from a *different* file of
        the same book (e.g. a Kindle-converted EPUB vs. the store EPUB on an
        Xteink), the XPointer would point into the wrong document. It is
        dropped so the client positions by percentage instead.
        """
        with self.connect() as db:
            book_key = self.resolve_book_key(db, username, document)
            row = db.execute("SELECT * FROM progress WHERE username=? AND book_key=?", (username, book_key)).fetchone()
            if not row and document != book_key:
                row = db.execute("SELECT * FROM progress WHERE username=? AND book_key=?", (username, document)).fetchone()
            if not row:
                return None
            record = self._record(row)
            same_file = record["document"] == document or document == record["book_key"]
            if row["position"] and same_file:
                try:
                    record["position"] = json.loads(row["position"])
                except ValueError:
                    pass
            if not same_file:
                record["progress"] = ""
                record["cross_file"] = True
            return record

    @staticmethod
    def _record(row: sqlite3.Row) -> dict:
        return {
            "document": row["document"],
            "book_key": row["book_key"],
            "progress": row["progress"],
            "percentage": row["percentage"],
            "device": row["device"],
            "device_id": row["device_id"],
            "title": row["title"],
            "authors": row["authors"],
            "timestamp": row["timestamp"],
            "version": row["version"],
        }

    def put_progress(self, username: str, body: dict) -> dict:
        document = _clean(body.get("document"), 128)
        progress = _clean(body.get("progress"), 2048)
        device = _clean(body.get("device"), 128)
        device_id = _clean(body.get("device_id"), 128)
        try:
            percentage = float(body.get("percentage"))
        except (TypeError, ValueError):
            percentage = None
        if not document or not progress or percentage is None or not device:
            raise ApiError(HTTPStatus.FORBIDDEN, "invalid_fields", "document, progress, percentage and device are required.")
        percentage = min(max(percentage, 0.0), 1.0)
        book_key = _clean(body.get("book_key"), 512)
        base_version = body.get("base_version")
        if base_version is not None:
            try:
                base_version = int(base_version)
            except (TypeError, ValueError):
                raise ApiError(HTTPStatus.BAD_REQUEST, "invalid_fields", "base_version must be a number.")
        force = bool(body.get("force"))
        now = int(time.time())
        # CrossPoint (Xteink) and other clients send {"metadata": {...}}.
        metadata = body.get("metadata") if isinstance(body.get("metadata"), dict) else {}
        title = _clean(body.get("title") or metadata.get("title"))
        authors = _clean(body.get("authors") or metadata.get("authors"))
        position = body.get("position")
        position_json = json.dumps(position)[:1024] if isinstance(position, dict) else ""

        with self.lock, self.connect() as db:
            if not book_key:
                alias = db.execute(
                    "SELECT book_key FROM aliases WHERE username=? AND document=?", (username, document)
                ).fetchone()
                if alias:
                    book_key = alias["book_key"]
                elif title:
                    # Link this file to the same book on other devices by title/author.
                    book_key = book_key_for(title, authors) or ""
            if book_key:
                db.execute(
                    "INSERT OR REPLACE INTO aliases(username, document, book_key) VALUES(?,?,?)",
                    (username, document, book_key),
                )
            else:
                book_key = document
            current = db.execute("SELECT * FROM progress WHERE username=? AND book_key=?", (username, book_key)).fetchone()
            seen_here = db.execute(
                "SELECT 1 FROM device_progress WHERE username=? AND book_key=? AND device_id=?",
                (username, book_key, device_id or device),
            ).fetchone()
            db.execute(
                "INSERT OR REPLACE INTO device_progress(username, book_key, device_id, device, percentage, timestamp) "
                "VALUES(?,?,?,?,?,?)",
                (username, book_key, device_id or device, device, percentage, now),
            )
            if (
                current is not None
                and base_version is None
                and not force
                and not seen_here
                and current["device_id"] != device_id
                and percentage < float(current["percentage"]) - 0.001
            ):
                # A device syncing this book for the first time, without a
                # base version (plain KOSync / CrossPoint), must not drag the
                # shared position back. Keep it as this device's progress
                # only; its next fetch returns the further position.
                result = {
                    "document": document,
                    "book_key": book_key,
                    "timestamp": int(current["timestamp"]),
                    "version": int(current["version"]),
                    "kept": "remote",
                }
                kept_remote = True
            else:
                kept_remote = False
            if (
                current is not None
                and base_version is not None
                and not force
                and int(current["version"]) > int(base_version)
                and current["device_id"] != device_id
                and abs(float(current["percentage"]) - percentage) > 0.0005
            ):
                raise ApiError(
                    HTTPStatus.CONFLICT,
                    "conflict",
                    "Another device has newer progress for this book.",
                    {"current": self._record(current)},
                )
            if not kept_remote:
                version = (int(current["version"]) if current else 0) + 1
                title = title or (current["title"] if current else "")
                authors = authors or (current["authors"] if current else "")
                db.execute(
                    "INSERT OR REPLACE INTO progress(username, book_key, document, progress, percentage, device, "
                    "device_id, title, authors, timestamp, version, position) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                    (username, book_key, document, progress, percentage, device, device_id, title, authors, now, version,
                     position_json),
                )
                result = {"document": document, "book_key": book_key, "timestamp": now, "version": version}
        self.touch_device(username, device_id, name=device)
        return result

    def list_books(self, username: str) -> list[dict]:
        with self.connect() as db:
            books = [self._record(r) for r in db.execute(
                "SELECT * FROM progress WHERE username=? ORDER BY timestamp DESC", (username,)
            ).fetchall()]
            per_device: dict[str, list[dict]] = {}
            for r in db.execute(
                "SELECT book_key, device_id, device, percentage, timestamp FROM device_progress WHERE username=? "
                "ORDER BY timestamp DESC",
                (username,),
            ).fetchall():
                per_device.setdefault(r["book_key"], []).append(dict(r))
        for book in books:
            book["devices"] = per_device.get(book["book_key"], [])
        return books

    def delete_book(self, username: str, book_key: str) -> None:
        with self.lock, self.connect() as db:
            for table in ("progress", "device_progress", "aliases"):
                db.execute(f"DELETE FROM {table} WHERE username=? AND book_key=?", (username, book_key))


# ---------------------------------------------------------------------------
# Web dashboard rendering
# ---------------------------------------------------------------------------

CSS = """
:root{--bg:#f6f5f2;--card:#fff;--ink:#1d1d1f;--muted:#6b6b70;--line:#e4e2dd;--accent:#2f6f5e;--accent-ink:#fff;--bar:#e9e7e1;--warn:#a5481d}
@media (prefers-color-scheme:dark){:root{--bg:#141414;--card:#1e1e1f;--ink:#ededed;--muted:#a0a0a6;--line:#2f2f31;--accent:#6fbfa7;--accent-ink:#0d1f1a;--bar:#2b2b2d;--warn:#ef8e63}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px 64px}header{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
h1{font-size:1.5rem;margin:0}h2{font-size:1.1rem;margin:32px 0 12px}.muted{color:var(--muted)}.small{font-size:.875rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:12px}
.book-title{font-weight:600}.row{display:flex;justify-content:space-between;gap:12px;align-items:baseline;flex-wrap:wrap}
.bar{height:8px;background:var(--bar);border-radius:4px;overflow:hidden;margin:8px 0}.bar>span{display:block;height:100%;background:var(--accent)}
.devices{list-style:none;margin:8px 0 0;padding:0}.devices li{display:flex;justify-content:space-between;gap:8px;font-size:.875rem;padding:2px 0;color:var(--muted)}
.devices li.latest{color:var(--ink);font-weight:600}
button,.btn{background:var(--accent);color:var(--accent-ink);border:0;border-radius:8px;padding:10px 16px;font:inherit;font-weight:600;cursor:pointer;text-decoration:none;display:inline-block}
button.link{background:none;color:var(--warn);padding:0;font-weight:400;font-size:.875rem}
.code{font:700 2.25rem/1.2 ui-monospace,Menlo,monospace;letter-spacing:.3em;margin:8px 0}
ol{padding-left:20px}input{font:inherit;padding:10px;border:1px solid var(--line);border-radius:8px;width:100%;background:var(--card);color:var(--ink)}
.empty{text-align:center;padding:32px 16px}.error{color:var(--warn)}form.inline{display:inline}
"""


def _ago(ts: int) -> str:
    delta = max(0, int(time.time()) - int(ts or 0))
    if delta < 60:
        return "just now"
    if delta < 3600:
        return f"{delta // 60} min ago"
    if delta < 86400:
        return f"{delta // 3600} h ago"
    days = delta // 86400
    return "yesterday" if days == 1 else f"{days} days ago"


def _page(title: str, body: str) -> bytes:
    return (
        "<!doctype html><html lang=en><head><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<title>{html.escape(title)}</title><style>{CSS}</style></head><body><main>{body}</main></body></html>"
    ).encode()


def render_login(error: str = "") -> bytes:
    err = f"<p class=error>{html.escape(error)}</p>" if error else ""
    return _page(
        "Reading Sync",
        "<h1>Reading Sync</h1><p class=muted>Sign in to see your books and devices.</p>"
        f"<div class=card><form method=post action=/login>{err}"
        "<label for=pw>Dashboard password</label><input id=pw type=password name=password autofocus>"
        "<p><button type=submit>Sign in</button></p></form></div>",
    )


def render_dashboard(store: Store, csrf: str, server_url: str) -> bytes:
    e = html.escape
    books = store.list_books(OWNER)
    devices = store.list_devices(OWNER)
    codes = store.active_pair_codes(OWNER)
    parts = [
        "<header><h1>Reading Sync</h1>"
        f"<form method=post action=/logout class=inline><input type=hidden name=csrf value={e(csrf)}>"
        "<button class=link type=submit>Sign out</button></form></header>",
        "<p class=muted>Your place in every book, on every device.</p>",
    ]

    parts.append("<h2>Books</h2>")
    if not books:
        parts.append(
            "<div class='card empty'><p>No reading progress yet.</p>"
            "<p class='muted small'>Pair a device below, open a book and turn a page. It shows up here when you close the book.</p></div>"
        )
    for book in books:
        pct = round(book["percentage"] * 100, 1)
        title = book["title"] or book["book_key"]
        authors = f"<div class='muted small'>{e(book['authors'])}</div>" if book["authors"] else ""
        rows = []
        for d in book["devices"]:
            cls = " class=latest" if d["device_id"] == book["device_id"] else ""
            rows.append(
                f"<li{cls}><span>{e(d['device'] or 'Unknown device')}</span>"
                f"<span>{round(d['percentage'] * 100, 1)}% · {_ago(d['timestamp'])}</span></li>"
            )
        parts.append(
            f"<div class=card><div class=row><div><div class=book-title>{e(title)}</div>{authors}</div>"
            f"<div><strong>{pct}%</strong></div></div>"
            f"<div class=bar><span style='width:{pct}%'></span></div>"
            f"<div class='muted small'>Latest: {e(book['device'] or 'Unknown')} · {_ago(book['timestamp'])}</div>"
            f"<ul class=devices>{''.join(rows)}</ul></div>"
        )

    parts.append("<h2>Devices</h2>")
    if not devices:
        parts.append("<div class='card empty muted'>No devices yet.</div>")
    for d in devices:
        label = d["name"] or d["model"] or d["device_id"][:8]
        meta = " · ".join(x for x in (d["model"] if d["model"] != label else "", "paired" if d["paired"] else "password login") if x)
        parts.append(
            f"<div class=card><div class=row><div><strong>{e(label)}</strong>"
            f"<div class='muted small'>{e(meta)} · last synced {_ago(d['last_seen'])}</div></div>"
            f"<form method=post action=/devices/remove class=inline><input type=hidden name=csrf value={e(csrf)}>"
            f"<input type=hidden name=device_id value='{e(d['device_id'])}'>"
            "<button class=link type=submit>Remove</button></form></div></div>"
        )

    parts.append("<h2>Add a device</h2><div class=card>")
    if codes:
        code = codes[0]
        parts.append(
            f"<p class=muted>Pairing code (valid for {max(1, (code['expires_at'] - int(time.time())) // 60)} more minutes):</p>"
            f"<div class=code>{e(code['code'])}</div>"
        )
    parts.append(
        "<ol><li>On the Kindle or Boox, open KOReader.</li>"
        "<li>Go to <strong>Menu → Tools → KindleOS → Cross-device sync → Pair this device</strong>.</li>"
        f"<li>Enter the server address <strong>{e(server_url)}</strong> and the pairing code.</li></ol>"
        f"<form method=post action=/pair><input type=hidden name=csrf value={e(csrf)}>"
        f"<button type=submit>{'New pairing code' if codes else 'Get a pairing code'}</button></form>"
        "</div>"
    )
    parts.append(
        "<div class=card><strong>Xteink X4 (CrossPoint) and other sync apps</strong>"
        "<ol><li>On the X4, open <strong>Settings → CrossPoint Sync</strong>.</li>"
        f"<li>Set <strong>Sync Server URL</strong> to <strong>{e(server_url)}</strong>, "
        f"<strong>Username</strong> to <strong>{OWNER}</strong> and <strong>Password</strong> to your dashboard password, "
        "then choose <strong>Authenticate</strong>.</li>"
        "<li>Keep <strong>Send Document Metadata</strong> on so the X4 is matched to the same book on your Kindle and Boox, "
        "even when the files differ.</li>"
        "<li>In a book, run <strong>Sync</strong> from the reader menu. With <strong>Smart Sync</strong> it jumps ahead or "
        "uploads by itself.</li></ol>"
        "<p class='muted small'>KOReader's built-in Progress sync works the same way: custom server, this address, "
        f"user <strong>{OWNER}</strong>, dashboard password. These devices sign in with the password, so to lock one out, "
        "restart the server with a new <code>--admin-password</code>.</p></div>"
    )
    parts.append(f"<p class='muted small'>Account name: <strong>{OWNER}</strong> · Server v{SERVER_VERSION}</p>")
    return _page("Reading Sync", "".join(parts))


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class SyncHandler(BaseHTTPRequestHandler):
    server_version = f"KindleSyncServer/{SERVER_VERSION}"
    store: Store = None  # type: ignore[assignment]
    sessions: dict = {}
    open_registration = False
    throttle: Throttle = None  # type: ignore[assignment]

    def log_message(self, fmt, *args):  # quieter, single-line logs
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers ----------------------------------------------------------
    def _send(self, status: int, body: bytes, content_type: str, headers: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload) -> None:
        self._send(status, json.dumps(payload).encode(), "application/vnd.koreader.v1+json")

    def _html(self, body: bytes, status: int = 200, headers: dict | None = None) -> None:
        self._send(status, body, "text/html; charset=utf-8", headers)

    def _redirect(self, location: str, headers: dict | None = None) -> None:
        h = {"Location": location}
        h.update(headers or {})
        self._send(HTTPStatus.SEE_OTHER, b"", "text/plain", h)

    def _body_bytes(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise ApiError(HTTPStatus.BAD_REQUEST, "bad_length", "Invalid Content-Length.")
        if length > MAX_BODY:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "too_large", "Request body too large.")
        return self.rfile.read(length) if length > 0 else b""

    def _json_body(self) -> dict:
        raw = self._body_bytes()
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ApiError(HTTPStatus.BAD_REQUEST, "bad_json", "Request body is not valid JSON.")
        if not isinstance(data, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "bad_json", "Request body must be a JSON object.")
        return data

    def _form(self) -> dict:
        data = parse_qs(self._body_bytes().decode("utf-8", "replace"))
        return {k: v[0] for k, v in data.items()}

    def _client(self) -> str:
        """Client address; behind a local reverse proxy (Tailscale Funnel,
        Caddy) every request comes from loopback, so use the forwarded one."""
        peer = self.client_address[0]
        forwarded = self.headers.get("X-Forwarded-For", "")
        if forwarded and (peer.startswith("127.") or peer == "::1"):
            return forwarded.split(",")[-1].strip() or peer
        return peer

    def _check_throttle(self) -> None:
        if self.throttle.blocked(self._client()):
            raise ApiError(
                HTTPStatus.TOO_MANY_REQUESTS,
                "too_many_attempts",
                "Too many failed sign-in attempts. Try again in 15 minutes.",
            )

    def _auth_user(self) -> str:
        self._check_throttle()
        user = self.headers.get("x-auth-user", "")
        key = self.headers.get("x-auth-key", "")
        if not self.store.authenticate(user, key):
            self.throttle.fail(self._client())
            raise ApiError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Unauthorized. Pair this device again.")
        return user

    def _session(self) -> str | None:
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        morsel = cookie.get("ksync_session")
        if not morsel:
            return None
        expires = self.sessions.get(morsel.value)
        if not expires or expires < time.time():
            self.sessions.pop(morsel.value, None)
            return None
        return morsel.value

    def _csrf(self, session: str) -> str:
        secret = self.store.get_setting("secret") or ""
        return hmac.new(secret.encode(), session.encode(), hashlib.sha256).hexdigest()[:32]

    def _server_url(self) -> str:
        host = self.headers.get("Host") or f"{self.server.server_address[0]}:{self.server.server_address[1]}"
        proto = self.headers.get("X-Forwarded-Proto", "http")
        return f"{proto}://{host}"

    # -- dispatch ---------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self._dispatch("GET")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        try:
            if path in ("/healthcheck", "/healthstatus") and method == "GET":
                return self._json(200, {"state": "OK", "version": SERVER_VERSION})
            if path == "/users/create" and method == "POST":
                return self._users_create()
            if path == "/users/auth" and method == "GET":
                self._auth_user()
                return self._json(200, {"authorized": "OK"})
            if path == "/syncs/progress" and method == "PUT":
                user = self._auth_user()
                return self._json(200, self.store.put_progress(user, self._json_body()))
            if path.startswith("/syncs/progress/") and method == "GET":
                user = self._auth_user()
                document = unquote(path[len("/syncs/progress/"):])
                record = self.store.get_progress(user, document)
                if record is None and "position_kinds" in urlparse(self.path).query:
                    # CrossPoint treats 404 as "no progress yet" (and uploads);
                    # stock KOReader expects the reference server's empty object.
                    raise ApiError(HTTPStatus.NOT_FOUND, "not_found", "No progress for this document yet.")
                return self._json(200, record or {})
            if path == "/v1/pair" and method == "POST":
                return self._pair()
            if path == "/v1/books" and method == "GET":
                user = self._auth_user()
                return self._json(200, {"books": self.store.list_books(user)})
            return self._web(method, path)
        except ApiError as err:
            payload = {"code": err.code, "message": err.message}
            payload.update(err.extra)
            return self._json(err.status, payload)
        except Exception as err:  # pragma: no cover - last-resort safety net
            self.log_error("unhandled error: %r", err)
            return self._json(500, {"code": "server_error", "message": "Unexpected server error."})

    def _users_create(self) -> None:
        if not self.open_registration:
            raise ApiError(
                HTTPStatus.PAYMENT_REQUIRED, "registration_closed", "Registration is disabled. Pair the device with a code instead."
            )
        body = self._json_body()
        username = _clean(body.get("username"), 64)
        password = _clean(body.get("password"), 128)
        if not username or not password:
            raise ApiError(HTTPStatus.FORBIDDEN, "invalid_fields", "Username and password are required.")
        if not self.store.create_user(username, password):
            raise ApiError(HTTPStatus.PAYMENT_REQUIRED, "user_exists", "Username is already registered.")
        self._json(201, {"username": username})

    def _pair(self) -> None:
        body = self._json_body()
        code = _clean(body.get("code"), 16)
        device_id = _clean(body.get("device_id"), 128) or secrets.token_hex(16)
        if not code:
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid_fields", "A pairing code is required.")
        self._check_throttle()
        try:
            username, key = self.store.claim_pair_code(
                code, device_id, _clean(body.get("device_name"), 128), _clean(body.get("device_model"), 128)
            )
        except ApiError:
            self.throttle.fail(self._client())
            raise
        self._json(200, {"username": username, "userkey": key, "device_id": device_id, "server_version": SERVER_VERSION})

    # -- web dashboard ----------------------------------------------------
    def _web(self, method: str, path: str) -> None:
        session = self._session()
        if path == "/login" and method == "POST":
            form = self._form()
            if self.throttle.blocked(self._client()):
                return self._html(render_login("Too many failed attempts. Try again in 15 minutes."), 429)
            if _check_password(form.get("password", ""), self.store.get_setting("admin_password") or ""):
                token = secrets.token_urlsafe(32)
                self.sessions[token] = time.time() + SESSION_TTL
                cookie = f"ksync_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}"
                if self.headers.get("X-Forwarded-Proto", "").lower() == "https":
                    cookie += "; Secure"
                return self._redirect("/", {"Set-Cookie": cookie})
            self.throttle.fail(self._client())
            time.sleep(0.5)
            return self._html(render_login("That password is not right."), 401)
        if path in ("/", "/login") and method == "GET":
            if not session:
                return self._html(render_login())
            if path == "/login":
                return self._redirect("/")
            return self._html(render_dashboard(self.store, self._csrf(session), self._server_url()))
        if method == "POST" and path in ("/logout", "/pair", "/devices/remove"):
            if not session:
                return self._redirect("/")
            form = self._form()
            if not hmac.compare_digest(form.get("csrf", ""), self._csrf(session)):
                return self._html(_page("Error", "<p class=error>Form expired. Go back and try again.</p>"), 403)
            if path == "/logout":
                self.sessions.pop(session, None)
                return self._redirect("/", {"Set-Cookie": "ksync_session=; Path=/; Max-Age=0"})
            if path == "/pair":
                self.store.create_pair_code(OWNER)
            elif path == "/devices/remove":
                self.store.remove_device(OWNER, form.get("device_id", ""))
            return self._redirect("/")
        self._json(404, {"code": "not_found", "message": "Not found."})


def build_server(host: str, port: int, data_dir: str, admin_password: str | None = None, open_registration: bool = False):
    os.makedirs(data_dir, exist_ok=True)
    store = Store(os.path.join(data_dir, "sync.sqlite3"))
    store.ensure_owner()
    if not store.get_setting("secret"):
        store.set_setting("secret", secrets.token_hex(32))
    generated = None
    password = admin_password
    if not password and not store.get_setting("admin_password"):
        password = generated = secrets.token_urlsafe(9)
    if password:
        store.set_setting("admin_password", _hash_password(password))
        # KOReader's built-in Progress sync logs in with md5(password), so the
        # owner account accepts the dashboard password from stock clients too.
        store.set_userkey(OWNER, hashlib.md5(password.encode()).hexdigest())
    handler = type(
        "BoundSyncHandler",
        (SyncHandler,),
        {"store": store, "sessions": {}, "open_registration": open_registration, "throttle": Throttle()},
    )
    httpd = ThreadingHTTPServer((host, port), handler)
    return httpd, store, generated


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Cross-device reading sync server for KOReader")
    parser.add_argument("--host", default=os.environ.get("KSYNC_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("KSYNC_PORT", "8081")))
    parser.add_argument("--data", default=os.environ.get("KSYNC_DATA", "./sync-data"), help="directory for the database")
    parser.add_argument("--admin-password", default=os.environ.get("KSYNC_ADMIN_PASSWORD"))
    parser.add_argument(
        "--open-registration",
        action="store_true",
        default=os.environ.get("KSYNC_OPEN_REGISTRATION") == "1",
        help="allow KOReader's built-in Progress sync to register new accounts",
    )
    args = parser.parse_args(argv)
    httpd, _, generated = build_server(args.host, args.port, args.data, args.admin_password, args.open_registration)
    print(f"Reading Sync server v{SERVER_VERSION} listening on http://{args.host}:{args.port}")
    if generated:
        print(f"Dashboard password (shown once, change with --admin-password): {generated}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
