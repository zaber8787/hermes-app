"""Durable notification events / deliveries / read ledger (STEERWEB R6).

One SQLite file inside the profile's HERMES home (never the CORE tree). The
ledger is the cross-device convergence record: WHAT happened (events), WHICH
transports were told (deliveries), and WHO acknowledged (read_events). It
stores whitelisted summaries only — never tool arguments, commands, topics or
secrets; payloads follow the same redaction/byte-cap discipline as approvals.

event_id is a STABLE hash of (owner scope, run_id, kind, source_id): the same
semantic event across reconnects and restarts. delivery_id is per transport
attempt phase. Nothing here claims third-party transport exact-once.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
import threading
import time
from pathlib import Path

SCHEMA_VERSION = 1
PAGE_LIMIT = 100
LOCK = threading.RLock()
_STORES: dict[str, sqlite3.Connection] = {}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(version INTEGER);
CREATE TABLE IF NOT EXISTS events(
  event_id TEXT PRIMARY KEY,
  owner_scope TEXT NOT NULL,
  run_id TEXT,
  sid TEXT,
  kind TEXT NOT NULL,
  source_id TEXT NOT NULL,
  created_seq INTEGER NOT NULL,
  payload TEXT NOT NULL,
  created_at REAL NOT NULL,
  read_at REAL
);
CREATE INDEX IF NOT EXISTS events_order ON events(owner_scope, created_seq);
CREATE TABLE IF NOT EXISTS deliveries(
  delivery_id TEXT PRIMARY KEY,
  event_id TEXT NOT NULL,
  phase TEXT NOT NULL,
  channel TEXT NOT NULL,
  state TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 0,
  claimed_by TEXT,
  updated_at REAL NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS delivery_phases
  ON deliveries(event_id, phase, channel);
CREATE TABLE IF NOT EXISTS read_events(
  event_id TEXT NOT NULL,
  reader TEXT NOT NULL,
  ack_seq INTEGER NOT NULL,
  acked_at REAL NOT NULL,
  PRIMARY KEY(event_id, reader)
);
CREATE TABLE IF NOT EXISTS seq(meta_key TEXT PRIMARY KEY, next_seq INTEGER NOT NULL);
"""


def _conn_for(home_or_conn) -> sqlite3.Connection:
    if isinstance(home_or_conn, sqlite3.Connection):
        return home_or_conn
    path = str(Path(home_or_conn).resolve() / "notification-events.sqlite")
    with LOCK:
        conn = _STORES.get(path)
        if conn is None:
            conn = sqlite3.connect(path, check_same_thread=False)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=FULL")
            conn.executescript(_SCHEMA)
            row = conn.execute("SELECT version FROM meta").fetchone()
            if row is None:
                conn.execute("INSERT INTO meta(version) VALUES(?)", (SCHEMA_VERSION,))
            elif int(row["version"]) > SCHEMA_VERSION:
                raise RuntimeError("notification events schema is newer than this plugin")
            conn.commit()
            _STORES[path] = conn
        return conn


def reset() -> None:
    with LOCK:
        for conn in _STORES.values():
            conn.close()
        _STORES.clear()


def close_all() -> None:
    reset()


def event_id_for(owner_scope: str, run_id: str | None, kind: str, source_id: str) -> str:
    return hashlib.sha256(
        f"{owner_scope}\0{run_id or ''}\0{kind}\0{source_id}".encode()).hexdigest()[:32]


def record_event(home, *, owner_scope, run_id, sid, kind, source_id,
                 payload: dict) -> tuple[str, bool]:
    """Idempotent append; returns (event_id, created). Reconnecting/restarting
    producers record the SAME event_id and never a second one."""
    conn = _conn_for(home)
    event_id = event_id_for(owner_scope, run_id, kind, source_id)
    now = time.time()
    with LOCK, conn:
        row = conn.execute("SELECT event_id FROM events WHERE event_id=?",
                           (event_id,)).fetchone()
        if row is not None:
            return event_id, False
        seq_row = conn.execute("SELECT next_seq FROM seq WHERE meta_key='events'").fetchone()
        seq = int(seq_row["next_seq"]) if seq_row else 1
        conn.execute("INSERT INTO seq(meta_key, next_seq) VALUES('events', ?)"
                     " ON CONFLICT(meta_key) DO UPDATE SET next_seq=?", (seq + 1, seq + 1))
        conn.execute(
            "INSERT INTO events(event_id, owner_scope, run_id, sid, kind, source_id,"
            " created_seq, payload, created_at) VALUES(?,?,?,?,?,?,?,?,?)",
            (event_id, owner_scope, run_id, sid, kind, source_id, seq,
             json.dumps(payload, ensure_ascii=False, separators=(",", ":")), now))
    return event_id, True


def events_after(home, owner_scope: str, after_seq: int = 0,
                 limit: int = PAGE_LIMIT) -> tuple[list[dict], bool, int]:
    conn = _conn_for(home)
    with LOCK:
        rows = conn.execute(
            "SELECT * FROM events WHERE owner_scope=? AND created_seq>?"
            " ORDER BY created_seq LIMIT ?", (owner_scope, after_seq, limit + 1)).fetchall()
        head = conn.execute("SELECT next_seq FROM seq WHERE meta_key='events'").fetchone()
    items = [_row_to_event(conn, dict(r)) for r in rows[:limit]]
    return items, len(rows) > limit, int(head["next_seq"]) - 1 if head else 0


def _row_to_event(conn, item: dict) -> dict:
    item["payload"] = json.loads(item["payload"])
    read = conn.execute(
        "SELECT COUNT(*) c FROM read_events WHERE event_id=?",
        (item["event_id"],)).fetchone()["c"]
    item["read_by"] = int(read)
    return item


def get_event(home, owner_scope: str, event_id: str) -> dict | None:
    conn = _conn_for(home)
    with LOCK:
        row = conn.execute("SELECT * FROM events WHERE owner_scope=? AND event_id=?",
                           (owner_scope, event_id)).fetchone()
    return _row_to_event(conn, dict(row)) if row else None


def mark_read(home, owner_scope: str, event_id: str, reader: str) -> dict | None:
    """Idempotent per-reader ack. read != approve; it only converges later
    alerts and stops un-sent reminders."""
    conn = _conn_for(home)
    now = time.time()
    with LOCK, conn:
        row = conn.execute("SELECT created_seq FROM events WHERE owner_scope=? AND event_id=?",
                           (owner_scope, event_id)).fetchone()
        if row is None:
            return None
        conn.execute(
            "INSERT INTO read_events(event_id, reader, ack_seq, acked_at) VALUES(?,?,?,?)"
            " ON CONFLICT(event_id, reader) DO NOTHING", (event_id, reader, row["created_seq"], now))
        conn.execute("UPDATE events SET read_at=COALESCE(read_at,?) WHERE event_id=?",
                     (now, event_id))
    return {"event_id": event_id, "read": True}


def is_read(home, event_id: str) -> bool:
    conn = _conn_for(home)
    with LOCK:
        return conn.execute("SELECT 1 FROM read_events WHERE event_id=?",
                            (event_id,)).fetchone() is not None


def claim_delivery(home, *, event_id, phase, channel, delivery_id, device_id):
    """One transport attempt per (event, phase, channel): the FIRST claimer may
    show; everyone else gets already_claimed. Claim BEFORE calling the output."""
    conn = _conn_for(home)
    now = time.time()
    with LOCK, conn:
        row = conn.execute(
            "SELECT * FROM deliveries WHERE event_id=? AND phase=? AND channel=?",
            (event_id, phase, channel)).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO deliveries(delivery_id, event_id, phase, channel, state,"
                " claimed_by, updated_at) VALUES(?,?,?,?,?,?,?)",
                (delivery_id, event_id, phase, channel, "claimed", device_id, now))
            return "claimed", delivery_id
        if row["state"] == "pending":  # ledger pre-claim races a browser claim
            conn.execute("UPDATE deliveries SET claimed_by=?, updated_at=?"
                         " WHERE delivery_id=?", (device_id, now, row["delivery_id"]))
            return "claimed", row["delivery_id"]
        return "already_claimed", row["delivery_id"]


def new_delivery(home, *, event_id, phase, channel, delivery_id, state="pending") -> None:
    conn = _conn_for(home)
    with LOCK, conn:
        conn.execute(
            "INSERT OR IGNORE INTO deliveries(delivery_id, event_id, phase, channel,"
            " state, updated_at) VALUES(?,?,?,?,?,?)",
            (delivery_id, event_id, phase, channel, state, time.time()))


def note_delivery(home, *, delivery_id, outcome, channel) -> str | None:
    """shown/failed/unknown outcomes from the claim owner only; a claim in the
    ledger records the fact, it never re-routes to another channel."""
    conn = _conn_for(home)
    now = time.time()
    with LOCK, conn:
        row = conn.execute("SELECT * FROM deliveries WHERE delivery_id=?",
                           (delivery_id,)).fetchone()
        if row is None or row["channel"] != channel:
            return None
        if outcome in {"shown", "failed", "unknown"}:
            conn.execute("UPDATE deliveries SET state=?, attempt=attempt+1, updated_at=?"
                         " WHERE delivery_id=?", (outcome, now, delivery_id))
        return row["state"]


def delivery_state(home, event_id: str, phase: str, channel: str) -> str | None:
    conn = _conn_for(home)
    with LOCK:
        row = conn.execute(
            "SELECT state FROM deliveries WHERE event_id=? AND phase=? AND channel=?",
            (event_id, phase, channel)).fetchone()
    return row["state"] if row else None


def sent_phases(home, event_id: str) -> list[tuple[str, str, str]]:
    conn = _conn_for(home)
    with LOCK:
        rows = conn.execute(
            "SELECT phase, channel, state FROM deliveries WHERE event_id=?",
            (event_id,)).fetchall()
    return [(r["phase"], r["channel"], r["state"]) for r in rows]
