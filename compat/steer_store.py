"""Durable run-scoped steer inbox sidecar (STEERWEB R3).

One SQLite file inside the profile's HERMES home (never the CORE tree). Keys
are (owner_scope, run_id, client_request_id): the owner scope is the core run
idempotency scope hash, so a durable receipt can never be read or written by a
different profile/key than the one that admitted the run. The sidecar never
stores agent objects, secrets, or topics — inputs are chat-grade private text
under the same file permissions as the rest of the home.

States: accepted -> staged -> delivered; accepted may end as not_delivered;
a staged batch without committed history evidence is outcome_unknown.
delivered means the row containing the batch committed to session history —
never that the model acted on the text.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
import threading
from pathlib import Path

SCHEMA_VERSION = 1
OUTSTANDING_LIMIT = 32          # R2: accepted+staged per run, else 429
RECEIPT_TTL_SECONDS = 30 * 86400  # terminal receipts retained 30 days, then 410
PAGE_LIMIT = 100

_LOCK = threading.RLock()
_STORES: dict[str, sqlite3.Connection] = {}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(version INTEGER);
CREATE TABLE IF NOT EXISTS runs(
  owner_scope TEXT NOT NULL,
  run_id TEXT NOT NULL,
  original_sid TEXT,
  resolved_sid TEXT,
  owner_epoch TEXT,
  closed_reason TEXT,
  closed_at REAL,
  next_seq INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY(owner_scope, run_id)
);
CREATE TABLE IF NOT EXISTS steers(
  steer_id TEXT PRIMARY KEY,
  owner_scope TEXT NOT NULL,
  run_id TEXT NOT NULL,
  key TEXT NOT NULL,
  digest TEXT NOT NULL,
  input TEXT NOT NULL,
  seq INTEGER NOT NULL,
  state TEXT NOT NULL,
  batch_id TEXT,
  row_id TEXT,
  error TEXT,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS steer_keys
  ON steers(owner_scope, run_id, key);
CREATE INDEX IF NOT EXISTS steer_order
  ON steers(owner_scope, run_id, seq);
CREATE TABLE IF NOT EXISTS batches(
  batch_id TEXT PRIMARY KEY,
  owner_scope TEXT NOT NULL,
  run_id TEXT NOT NULL,
  ordered_ids TEXT NOT NULL,
  state TEXT NOT NULL,
  row_id TEXT,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS purged_keys(
  owner_scope TEXT NOT NULL,
  run_id TEXT NOT NULL,
  key TEXT NOT NULL,
  purged_at REAL NOT NULL,
  PRIMARY KEY(owner_scope, run_id, key)
);
"""


def _now() -> float:
    import time
    return time.time()


def open_store(home) -> sqlite3.Connection:
    """Idempotent per-resolved-path open (auto_wake_store pattern)."""
    path = str(Path(home).resolve() / "steer-inbox.sqlite")
    with _LOCK:
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
                raise RuntimeError("steer store schema is newer than this plugin")
            conn.commit()
            _STORES[path] = conn
        return conn


def reset() -> None:
    with _LOCK:
        for conn in _STORES.values():
            conn.close()
        _STORES.clear()


def close_all() -> None:
    reset()


def _conn_for(home_or_conn) -> sqlite3.Connection:
    # Callers may pass either the profile home or an already-opened store
    # connection (steer_inbox opens once per operation).
    if isinstance(home_or_conn, sqlite3.Connection):
        return home_or_conn
    return open_store(home_or_conn)


def digest_of(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def derive_steer_id(owner_scope: str, run_id: str, key: str) -> str:
    return hashlib.sha256(
        f"{owner_scope}\0{run_id}\0{key}".encode("utf-8")).hexdigest()[:32]


def register_run(home, owner_scope: str, run_id: str, *, original_sid=None,
                 resolved_sid=None, owner_epoch=None) -> dict:
    conn = _conn_for(home)
    with _LOCK, conn:
        conn.execute(
            "INSERT INTO runs(owner_scope, run_id, original_sid, resolved_sid, owner_epoch)"
            " VALUES(?,?,?,?,?) ON CONFLICT(owner_scope, run_id) DO UPDATE SET"
            " resolved_sid=COALESCE(excluded.resolved_sid, resolved_sid),"
            " owner_epoch=COALESCE(excluded.owner_epoch, owner_epoch)",
            (owner_scope, run_id, original_sid, resolved_sid, owner_epoch))
    return get_run(home, owner_scope, run_id)


def get_run(home, owner_scope: str, run_id: str) -> dict | None:
    conn = _conn_for(home)
    with _LOCK:
        row = conn.execute("SELECT * FROM runs WHERE owner_scope=? AND run_id=?",
                           (owner_scope, run_id)).fetchone()
    return dict(row) if row else None


def seal_run(home, owner_scope: str, run_id: str, reason: str) -> dict:
    """Atomically stop admission + claims and retire unclaimed accepted items.

    Staged batches are NOT touched: a claimed batch must still be reconciled
    against the committed history (R3 item 6)."""
    conn = _conn_for(home)
    now = _now()
    with _LOCK, conn:
        conn.execute(
            "INSERT INTO runs(owner_scope, run_id, closed_reason, closed_at)"
            " VALUES(?,?,?,?) ON CONFLICT(owner_scope, run_id) DO UPDATE SET"
            " closed_reason=COALESCE(runs.closed_reason, excluded.closed_reason),"
            " closed_at=COALESCE(runs.closed_at, excluded.closed_at)",
            (owner_scope, run_id, reason, now))
        rows = conn.execute(
            "UPDATE steers SET state='not_delivered', error=?, updated_at=?"
            " WHERE owner_scope=? AND run_id=? AND state='accepted'"
            " RETURNING steer_id", (reason, now, owner_scope, run_id)).fetchall()
    return {"closed_reason": reason, "not_delivered": [r["steer_id"] for r in rows]}


def admit(home, owner_scope: str, run_id: str, *, key: str, input_text: str,
          original_sid=None, resolved_sid=None, owner_epoch=None) -> tuple[str, dict]:
    """Idempotent durable admission in ONE transaction.

    Returns (verdict, receipt): 'admitted' | 'duplicate' (same key, same
    digest — including after terminal) | 'conflict' (same key, other digest) |
    'closed' | 'queue_full' | 'expired'."""
    conn = _conn_for(home)
    digest = digest_of(input_text)
    steer_id = derive_steer_id(owner_scope, run_id, key)
    now = _now()
    with _LOCK, conn:
        if conn.execute("SELECT 1 FROM purged_keys WHERE owner_scope=? AND run_id=? AND key=?",
                        (owner_scope, run_id, key)).fetchone():
            return "expired", {"steer_id": steer_id}
        hit = conn.execute(
            "SELECT * FROM steers WHERE owner_scope=? AND run_id=? AND key=?",
            (owner_scope, run_id, key)).fetchone()
        if hit is not None:
            if hit["digest"] != digest:
                return "conflict", dict(hit)
            return "duplicate", dict(hit)
        run = conn.execute("SELECT * FROM runs WHERE owner_scope=? AND run_id=?",
                           (owner_scope, run_id)).fetchone()
        if run is not None and run["closed_reason"] is not None:
            return "closed", dict(run)
        outstanding = conn.execute(
            "SELECT COUNT(*) c FROM steers WHERE owner_scope=? AND run_id=?"
            " AND state IN ('accepted','staged')", (owner_scope, run_id)).fetchone()["c"]
        if outstanding >= OUTSTANDING_LIMIT:
            return "queue_full", {"count": outstanding}
        if run is None:
            conn.execute(
                "INSERT INTO runs(owner_scope, run_id, original_sid, resolved_sid, owner_epoch)"
                " VALUES(?,?,?,?,?)",
                (owner_scope, run_id, original_sid, resolved_sid, owner_epoch))
            seq = 1
            conn.execute("UPDATE runs SET next_seq=2 WHERE owner_scope=? AND run_id=?",
                         (owner_scope, run_id))
        else:
            seq = int(run["next_seq"])
            conn.execute("UPDATE runs SET next_seq=? WHERE owner_scope=? AND run_id=?",
                         (seq + 1, owner_scope, run_id))
        conn.execute(
            "INSERT INTO steers(steer_id, owner_scope, run_id, key, digest, input, seq,"
            " state, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
            (steer_id, owner_scope, run_id, key, digest, input_text, seq, "accepted", now, now))
        row = conn.execute("SELECT * FROM steers WHERE steer_id=?", (steer_id,)).fetchone()
    return "admitted", dict(row)


def list_steers(home, owner_scope: str, run_id: str, *, after_seq: int = 0,
                limit: int = PAGE_LIMIT) -> tuple[list[dict], bool]:
    conn = _conn_for(home)
    with _LOCK:
        rows = conn.execute(
            "SELECT * FROM steers WHERE owner_scope=? AND run_id=? AND seq>?"
            " ORDER BY seq LIMIT ?", (owner_scope, run_id, after_seq, limit + 1)).fetchall()
    items = [dict(r) for r in rows[:limit]]
    return items, len(rows) > limit


def get_steer(home, owner_scope: str, run_id: str, steer_id: str) -> dict | None:
    conn = _conn_for(home)
    with _LOCK:
        row = conn.execute(
            "SELECT * FROM steers WHERE owner_scope=? AND run_id=? AND steer_id=?",
            (owner_scope, run_id, steer_id)).fetchone()
    return dict(row) if row else None


def claim_batch(home, owner_scope: str, run_id: str, batch_id: str) -> list[dict] | None:
    """Claim every accepted item of the run (seq order) as one staged batch.

    Returns None when the run is sealed or nothing is accepted, so the caller
    appends NOTHING (an empty batch never exists)."""
    conn = _conn_for(home)
    now = _now()
    with _LOCK, conn:
        run = conn.execute("SELECT closed_reason FROM runs WHERE owner_scope=? AND run_id=?",
                           (owner_scope, run_id)).fetchone()
        if run is None or run["closed_reason"] is not None:
            return None
        rows = conn.execute(
            "SELECT * FROM steers WHERE owner_scope=? AND run_id=? AND state='accepted'"
            " ORDER BY seq", (owner_scope, run_id)).fetchall()
        if not rows:
            return None
        items = [dict(r) for r in rows]
        conn.execute(
            "UPDATE steers SET state='staged', batch_id=?, updated_at=?"
            " WHERE owner_scope=? AND run_id=? AND state='accepted'",
            (batch_id, now, owner_scope, run_id))
        conn.execute(
            "INSERT INTO batches(batch_id, owner_scope, run_id, ordered_ids, state, created_at)"
            " VALUES(?,?,?,?,?,?)",
            (batch_id, owner_scope, run_id,
             json.dumps([i["steer_id"] for i in items], separators=(",", ":")), "staged", now))
    return items


def confirm_batch(home, batch_id: str, row_id) -> None:
    """History-commit confirmation: the row carrying this batch's metadata is
    durable. Only exact batch metadata may promote a batch (R3 item 4)."""
    conn = _conn_for(home)
    now = _now()
    with _LOCK, conn:
        batch = conn.execute("SELECT * FROM batches WHERE batch_id=?", (batch_id,)).fetchone()
        if batch is None or batch["state"] == "delivered":
            return
        conn.execute("UPDATE batches SET state='delivered', row_id=? WHERE batch_id=?",
                     (str(row_id), batch_id))
        conn.execute(
            "UPDATE steers SET state='delivered', row_id=?, error=NULL, updated_at=?"
            " WHERE batch_id=?", (str(row_id), now, batch_id))


def mark_outcome_unknown(home, batch_id: str, reason: str) -> None:
    conn = _conn_for(home)
    now = _now()
    with _LOCK, conn:
        batch = conn.execute("SELECT * FROM batches WHERE batch_id=?",
                             (batch_id,)).fetchone()
        if batch is None or batch["state"] == "delivered":
            return
        conn.execute("UPDATE batches SET state='outcome_unknown' WHERE batch_id=?",
                     (batch_id,))
        conn.execute(
            "UPDATE steers SET state='outcome_unknown', error=?, updated_at=?"
            " WHERE batch_id=?", (reason, now, batch_id))


def staged_batches(home) -> list[dict]:
    conn = _conn_for(home)
    with _LOCK:
        rows = conn.execute(
            "SELECT * FROM batches WHERE state='staged' ORDER BY created_at").fetchall()
    out = []
    for row in rows:
        item = dict(row)
        item["ordered_ids"] = json.loads(item["ordered_ids"])
        out.append(item)
    return out


def prune_expired(home, now: float | None = None) -> int:
    """Terminal receipts live 30 days; purged keys answer later retries with
    410 expired, never as a fresh admission."""
    conn = _conn_for(home)
    cutoff = (now if now is not None else _now()) - RECEIPT_TTL_SECONDS
    removed = 0
    with _LOCK, conn:
        runs = conn.execute(
            "SELECT owner_scope, run_id FROM runs"
            " WHERE closed_reason IS NOT NULL AND closed_at IS NOT NULL AND closed_at < ?",
            (cutoff,)).fetchall()
        for run in runs:
            rows = conn.execute(
                "SELECT owner_scope, run_id, key FROM steers"
                " WHERE owner_scope=? AND run_id=?", (run["owner_scope"], run["run_id"])).fetchall()
            for row in rows:
                conn.execute(
                    "INSERT OR REPLACE INTO purged_keys(owner_scope, run_id, key, purged_at)"
                    " VALUES(?,?,?,?)",
                    (row["owner_scope"], row["run_id"], row["key"], _now()))
            conn.execute("DELETE FROM steers WHERE owner_scope=? AND run_id=?",
                         (run["owner_scope"], run["run_id"]))
            conn.execute("DELETE FROM batches WHERE owner_scope=? AND run_id=?",
                         (run["owner_scope"], run["run_id"]))
            removed += len(rows)
    return removed


def receipt_of(row: dict, *, epoch: str | None = None) -> dict:
    """Wire receipt for a steer row (R2 shape; never leaks digest/input here)."""
    receipt = {
        "object": "hermes.run.steer.receipt", "schema_version": 1,
        "steer_id": row["steer_id"], "run_id": row["run_id"],
        "sequence": int(row["seq"]), "state": row["state"],
        "client_request_id": row["key"],
    }
    if row.get("batch_id"):
        receipt["batch_id"] = row["batch_id"]
    if row.get("row_id"):
        receipt["row_id"] = row["row_id"]
    if row.get("error"):
        receipt["error"] = row["error"]
    if epoch is not None:
        receipt["server_epoch"] = epoch
    return receipt
