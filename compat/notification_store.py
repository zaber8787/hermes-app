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

SCHEMA_VERSION = 3
PAGE_LIMIT = 100
LOCK = threading.RLock()
_STORES: dict[str, sqlite3.Connection] = {}

# ONE outcome enum for every transport report (01412 audit m1). States an
# owner's delivery may END in differ per path; no producer may claim a later
# state than its own callback actually proves — an enqueue is never a send.
OUTCOME_STATES = frozenset({"pending", "queued", "claimed", "enqueued",
                            "sent", "shown", "failed", "unknown"})
CLIENT_OUTCOMES = frozenset({"shown", "failed", "unknown"})
SERVER_OUTCOMES = frozenset({"enqueued", "sent", "failed", "unknown"})
# What a note_delivery() report may legally END a delivery in.
REPORT_OUTCOMES = CLIENT_OUTCOMES | SERVER_OUTCOMES

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
  change_seq INTEGER NOT NULL DEFAULT 0,
  payload TEXT NOT NULL,
  created_at REAL NOT NULL,
  read_at REAL
);
CREATE INDEX IF NOT EXISTS events_order ON events(owner_scope, created_seq);
-- events_change is created AFTER migration (below): on a v1/v2 database the
-- column does not exist yet when _SCHEMA runs, and CREATE INDEX would raise.
CREATE TABLE IF NOT EXISTS deliveries(
  delivery_id TEXT PRIMARY KEY,
  event_id TEXT NOT NULL,
  phase TEXT NOT NULL,
  channel TEXT NOT NULL,
  state TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 0,
  claimed_by TEXT,
  show_token TEXT,
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
            elif int(row["version"]) < SCHEMA_VERSION:
                columns = {r["name"] for r in
                           conn.execute("PRAGMA table_info(deliveries)")}
                if "show_token" not in columns:  # v2: durable claim tokens
                    conn.execute("ALTER TABLE deliveries ADD COLUMN show_token TEXT")
                ecolumns = {r["name"] for r in
                            conn.execute("PRAGMA table_info(events)")}
                if "change_seq" not in ecolumns:  # v3: reads are observable
                    conn.execute("ALTER TABLE events ADD COLUMN change_seq INTEGER"
                                 " NOT NULL DEFAULT 0")
                    conn.execute("UPDATE events SET change_seq=created_seq"
                                 " WHERE change_seq=0")
                    conn.execute("CREATE INDEX IF NOT EXISTS events_change"
                                 " ON events(owner_scope, change_seq)")
                conn.execute("UPDATE meta SET version=?", (SCHEMA_VERSION,))
            # index creation is unconditional and post-migration: fresh v3 DBs
            # skip the branch, migrated DBs need the column to exist first.
            conn.execute("CREATE INDEX IF NOT EXISTS events_change"
                         " ON events(owner_scope, change_seq)")
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
        seq = _next_seq(conn)
        conn.execute(
            "INSERT INTO events(event_id, owner_scope, run_id, sid, kind, source_id,"
            " created_seq, change_seq, payload, created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
            (event_id, owner_scope, run_id, sid, kind, source_id, seq, seq,
             json.dumps(payload, ensure_ascii=False, separators=(",", ":")), now))
    return event_id, True


def _next_seq(conn) -> int:
    row = conn.execute("SELECT next_seq FROM seq WHERE meta_key='events'").fetchone()
    seq = int(row["next_seq"]) if row else 1
    conn.execute("INSERT INTO seq(meta_key, next_seq) VALUES('events', ?)"
                 " ON CONFLICT(meta_key) DO UPDATE SET next_seq=?", (seq + 1, seq + 1))
    return seq


def events_after(home, owner_scope: str, after_seq: int = 0,
                 limit: int = PAGE_LIMIT) -> tuple[list[dict], bool, int]:
    """Incremental view by CHANGE seq (01412 M2/M3): a read that converged on
    another device re-stamps the event's change_seq, so every device's cursor
    OBSERVES it. The third value is the highest change_seq actually DELIVERED
    on this page — the honest next cursor; an overflow page resumes from it
    and never skips to the global head."""
    conn = _conn_for(home)
    with LOCK:
        rows = conn.execute(
            "SELECT * FROM events WHERE owner_scope=? AND change_seq>?"
            " ORDER BY change_seq LIMIT ?", (owner_scope, after_seq, limit + 1)).fetchall()
    items = [_row_to_event(conn, dict(r)) for r in rows[:limit]]
    next_cursor = max([int(r["change_seq"]) for r in rows[:limit]], default=after_seq)
    return items, len(rows) > limit, next_cursor


def head_seq(home) -> int:
    conn = _conn_for(home)
    with LOCK:
        row = conn.execute("SELECT next_seq FROM seq WHERE meta_key='events'").fetchone()
    return int(row["next_seq"]) - 1 if row else 0


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
    alerts and stops un-sent reminders. A NEW ack re-stamps the event's
    change_seq (01412 M2) so every device's incremental cursor OBSERVES the
    convergence instead of keeping a phantom unread forever."""
    conn = _conn_for(home)
    now = time.time()
    with LOCK, conn:
        row = conn.execute("SELECT created_seq FROM events WHERE owner_scope=? AND event_id=?",
                           (owner_scope, event_id)).fetchone()
        if row is None:
            return None
        inserted = conn.execute(
            "INSERT INTO read_events(event_id, reader, ack_seq, acked_at) VALUES(?,?,?,?)"
            " ON CONFLICT(event_id, reader) DO NOTHING", (event_id, reader, row["created_seq"], now)).rowcount
        if inserted:
            conn.execute("UPDATE events SET read_at=COALESCE(read_at,?), change_seq=?"
                         " WHERE event_id=?", (now, _next_seq(conn), event_id))
    return {"event_id": event_id, "read": True}


def is_read(home, event_id: str) -> bool:
    conn = _conn_for(home)
    with LOCK:
        return conn.execute("SELECT 1 FROM read_events WHERE event_id=?",
                            (event_id,)).fetchone() is not None


def claim_delivery(home, *, event_id, phase, channel, delivery_id, device_id,
                   show_token=None):
    """One transport attempt per (event, phase, channel): the FIRST claimer may
    show; everyone else gets already_claimed. Claim BEFORE calling the output.
    A claim may carry a durable show_token: the SAME token a later delivery
    report must present to prove it comes from the claim owner (01412 M1)."""
    conn = _conn_for(home)
    now = time.time()
    with LOCK, conn:
        row = conn.execute(
            "SELECT * FROM deliveries WHERE event_id=? AND phase=? AND channel=?",
            (event_id, phase, channel)).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO deliveries(delivery_id, event_id, phase, channel, state,"
                " claimed_by, show_token, updated_at) VALUES(?,?,?,?,?,?,?,?)",
                (delivery_id, event_id, phase, channel, "claimed", device_id,
                 show_token, now))
            return "claimed", delivery_id
        if row["state"] == "pending":  # ledger pre-claim races a browser claim
            conn.execute("UPDATE deliveries SET state='claimed', claimed_by=?,"
                         " show_token=?, updated_at=? WHERE delivery_id=?",
                         (device_id, show_token, now, row["delivery_id"]))
            return "claimed", row["delivery_id"]
        return "already_claimed", row["delivery_id"]


def show_token_for(home, delivery_id: str) -> str | None:
    conn = _conn_for(home)
    with LOCK:
        row = conn.execute("SELECT show_token FROM deliveries WHERE delivery_id=?",
                           (delivery_id,)).fetchone()
    return row["show_token"] if row else None


def new_delivery(home, *, event_id, phase, channel, delivery_id, state="pending") -> None:
    conn = _conn_for(home)
    with LOCK, conn:
        conn.execute(
            "INSERT OR IGNORE INTO deliveries(delivery_id, event_id, phase, channel,"
            " state, updated_at) VALUES(?,?,?,?,?,?)",
            (delivery_id, event_id, phase, channel, state, time.time()))


def queue_delivery(home, *, event_id, phase, channel, delivery_id):
    """Pre-claim INTENT for a device to claim (01412 M5): the server records
    the pending delivery but NEVER owns the claim itself — a server-side
    claim would make every later device claim answer already_claimed.
    Returns (verdict, delivery_id); verdict 'queued' | 'already_<state>'."""
    conn = _conn_for(home)
    with LOCK, conn:
        row = conn.execute(
            "SELECT delivery_id, state FROM deliveries"
            " WHERE event_id=? AND phase=? AND channel=?",
            (event_id, phase, channel)).fetchone()
        if row is not None:
            return ("queued" if row["state"] == "pending"
                    else "already_" + row["state"]), row["delivery_id"]
        conn.execute(
            "INSERT INTO deliveries(delivery_id, event_id, phase, channel,"
            " state, updated_at) VALUES(?,?,?,?,?,?)",
            (delivery_id, event_id, phase, channel, "pending", time.time()))
        return "queued", delivery_id


def note_delivery(home, *, delivery_id, outcome, channel=None, event_id=None,
                  owner_scope=None, device_id=None, show_token=None) -> str | None:
    """Record a transport outcome. The trusted in-process server path reports
    (delivery_id, outcome, channel) only. A DEVICE report (01412 audit M1) is
    a TRANSACTION: owner, event, claim owner and the durable show token must
    ALL match the ledger row; any mismatch reads exactly like a delivery that
    does not exist. Reports use the ONE outcome enum (m1) — an unknown word
    never rewrites a state, and a browser row is never finalized without the
    token its claim minted."""
    if outcome not in REPORT_OUTCOMES:
        return None
    conn = _conn_for(home)
    now = time.time()
    with LOCK, conn:
        row = conn.execute("SELECT * FROM deliveries WHERE delivery_id=?",
                           (delivery_id,)).fetchone()
        if row is None or (channel is not None and row["channel"] != channel):
            return None
        if event_id is not None and row["event_id"] != event_id:
            return None
        if owner_scope is not None:
            event = conn.execute("SELECT owner_scope FROM events WHERE event_id=?",
                                 (row["event_id"],)).fetchone()
            if event is None or event["owner_scope"] != owner_scope:
                return None
        if device_id is not None and row["claimed_by"] != device_id:
            return None
        if row["channel"] == "browser":
            # the claim owner's durable token is the only accepted proof
            if row["state"] == "pending" or not row["show_token"]:
                return None
            if not show_token or show_token != row["show_token"]:
                return None
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
