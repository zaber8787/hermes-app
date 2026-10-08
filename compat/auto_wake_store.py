"""APPWAKE B durable admission ledger: per-report consumption, batches, quota.

This SQLite file (wake_ledger.db, next to cron_bridge.db) is the SINGLE
consumption record for auto-wakes. It is scoped by profile home + stable
delivery_key — credential rotation can never rebuild it, and nothing here
inherits the native run store's 24h TTL. The ledger and the run store are
DIFFERENT databases: no fake cross-DB atomicity. State machine per batch:

    reserved -> dispatching -> accepted -> terminal
       |            |  \\-> uncertain-consumed (never re-sent)
       |            \\--> (pre-stream rejection reverts to reserved)
       \\-> released (claim + quota reservation returned)

Consumed is final: accepted runs that fail, get cancelled, or answer
NO_REPLY all STAY consumed — a wake is never replayed to "fix" a bad
outcome. Only a PROVABLY undispatched reserved batch may release.
"""
from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
import threading
import time
from pathlib import Path

from .auto_wake import (BATCH_MAX, CANONICAL_INPUT, PROFILE_WAKE_LIMIT,
                        QUOTA_WINDOW_SECONDS, SESSION_WAKE_LIMIT,
                        is_ignored_report)

LEDGER_VERSION = 1
ADMIT_MAX_DELIVERY_IDS = 32
LEDGER_LOCK = threading.RLock()
_LEDGERS: dict[str, sqlite3.Connection] = {}

# Reviewed SessionDB seams, installed by compat._install_wake (fail-closed
# when absent): the read executor, the lease-key mapper, the lineage resolver.
_bindings = None


class LedgerUnavailable(RuntimeError):
    pass


def configure(*, reviewed):
    """compat.py records the fingerprint gate outcome here; with it absent
    every ledger path that touches SessionDB refuses (fail closed). The
    review-covered methods themselves are called on the acquired instance."""
    global _bindings
    _bindings = {"reviewed": reviewed}


def bindings_ready() -> bool:
    return _bindings is not None


def reset():
    global _bindings
    _bindings = None
    with LEDGER_LOCK:
        for conn in _LEDGERS.values():
            try:
                conn.close()
            except Exception:
                pass
        _LEDGERS.clear()


def open_ledger(home: Path) -> sqlite3.Connection:
    key = str(Path(home).resolve())
    with LEDGER_LOCK:
        conn = _LEDGERS.get(key)
        if conn is not None:
            try:
                conn.execute("SELECT 1").fetchone()
            except sqlite3.ProgrammingError:
                # 01413 m3: a cached handle closed out of band (test fixtures,
                # operator tooling) must be replaced, never handed back dead.
                _LEDGERS.pop(key, None)
                conn = None
            except Exception:
                pass  # busy/locked: same as HEAD — the CALLER sees the error
        if conn is None:
            Path(key).mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(Path(key) / "wake_ledger.db",
                                   check_same_thread=False, timeout=10.0)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA busy_timeout=10000")
            conn.execute("""CREATE TABLE IF NOT EXISTS wake_batches(
                batch_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                state TEXT NOT NULL, reason TEXT, run_id TEXT,
                canonical_input TEXT NOT NULL, batch_keys TEXT NOT NULL,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, terminal_at REAL)""")
            conn.execute("""CREATE TABLE IF NOT EXISTS wake_consumption(
                delivery_key TEXT PRIMARY KEY, batch_id TEXT, session_id TEXT NOT NULL,
                message_id INTEGER, report_order INTEGER, ignored INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)""")
            conn.execute("CREATE INDEX IF NOT EXISTS wb_window ON wake_batches(created_at)")
            conn.execute("CREATE INDEX IF NOT EXISTS wb_session ON wake_batches(session_id, state)")
            conn.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
            conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('version', ?)",
                         (str(LEDGER_VERSION),))
            cols = {r[1] for r in conn.execute("PRAGMA table_info(wake_batches)")}
            if "owner" not in cols:
                # SELFWAKE S3: request-owner association (backward-compatible;
                # legacy/App batches stay NULL = app/unknown, never taken over).
                conn.execute("ALTER TABLE wake_batches ADD COLUMN owner TEXT")
            conn.execute("""CREATE TABLE IF NOT EXISTS selfwake_chain(
                session_id TEXT PRIMARY KEY, fires INTEGER NOT NULL DEFAULT 0,
                last_fire_at REAL, fused INTEGER NOT NULL DEFAULT 0, updated_at REAL)""")
            cols = {r[1] for r in conn.execute("PRAGMA table_info(selfwake_chain)")}
            if "fails" not in cols:
                # SELFWAKE S4: consecutive failed/uncertain settlements;
                # 3 in a row fault-fuses the lineage (audited, manual reset).
                conn.execute("ALTER TABLE selfwake_chain ADD COLUMN fails"
                             " INTEGER NOT NULL DEFAULT 0")
            conn.execute("""CREATE TABLE IF NOT EXISTS selfwake_audit(
                seq INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL,
                session_original TEXT, session_resolved TEXT, trigger TEXT,
                key_prefixes TEXT, row_ids TEXT, batch_id TEXT, run_id TEXT,
                phase TEXT NOT NULL, from_state TEXT, to_state TEXT, reason TEXT,
                quota_used INTEGER, chain_count INTEGER, latency REAL)""")
            conn.commit()
            # 01413 m3: the managed handle goes INTO the cache — an opener
            # that builds a fresh connection per call defeats reset() (which
            # closes what the cache holds) and leaks handles.
            _LEDGERS[key] = conn
        return conn


def _now(now=None):
    return time.time() if now is None else now


def _quota(conn, session_id: str, at: float):
    since = at - QUOTA_WINDOW_SECONDS

    def used(where, params):
        row = conn.execute(
            "SELECT COUNT(*) c FROM wake_batches WHERE created_at > ? AND state != 'released'"
            + where, (since, *params)).fetchone()
        return int(row["c"])
    session_used = used(" AND session_id = ?", (session_id,))
    profile_used = used("", ())
    return {
        "session_used": session_used, "session_limit": SESSION_WAKE_LIMIT,
        "session_remaining": max(0, SESSION_WAKE_LIMIT - session_used),
        "profile_used": profile_used, "profile_limit": PROFILE_WAKE_LIMIT,
        "profile_remaining": max(0, PROFILE_WAKE_LIMIT - profile_used),
        "window_seconds": int(QUOTA_WINDOW_SECONDS),
    }


def _find_report(db, resolved: str, key: str):
    """One row by delivery_key across the session's compression lineage."""
    sql = """WITH RECURSIVE lineage(id) AS (
        SELECT ? UNION
        SELECT s.parent_session_id FROM sessions s JOIN lineage l ON s.id = l.id
        JOIN sessions p ON p.id = s.parent_session_id WHERE p.end_reason = 'compression'
    ) SELECT m.id AS id, m.timestamp AS timestamp, m.content AS content,
        json_extract(m.display_metadata, '$.hermes_app_cron.schema') AS sch
        FROM messages m JOIN lineage l ON m.session_id = l.id
        WHERE m.role = 'user' AND m.display_kind = 'internal_notification'
        AND json_extract(m.display_metadata, '$.hermes_app_cron.delivery_key') = ?
        LIMIT 1"""
    rows = db._read_all(sql, (resolved, key))
    return rows[0] if rows else None


def _session_busy(db, resolved: str, at: float) -> bool:
    try:
        key = db._session_turn_lease_key(resolved)
        rows = db._read_all(
            "SELECT 1 FROM session_turn_leases WHERE conversation_id = ? AND expires_at > ?"
            " LIMIT 1", (key, at))
        return bool(rows)
    except Exception:
        return True  # fail closed: an unprovable session is "busy", retry later


def _batch_view(conn, batch_id: str):
    batch = conn.execute("SELECT * FROM wake_batches WHERE batch_id = ?",
                         (batch_id,)).fetchone()
    if batch is None:
        return None
    rows = conn.execute(
        "SELECT delivery_key, state, ignored, message_id FROM wake_consumption"
        " WHERE batch_id = ? ORDER BY report_order", (batch_id,)).fetchall()
    return {
        "object": "hermes_app.wake_receipt", "batch_id": batch_id,
        "session_id": batch["session_id"], "state": batch["state"],
        "reason": batch["reason"], "run_id": batch["run_id"],
        "canonical_input": batch["canonical_input"],
        "delivery_keys": json.loads(batch["batch_keys"]),
        "rows": [dict(r) for r in rows],
        "created_at": batch["created_at"], "terminal_at": batch["terminal_at"],
    }


def admit(home: Path, *, session_id: str, resolved: str, keys, db, now=None, owner=None):
    """Validate + claim one batch inside ONE ledger transaction."""
    if _bindings is None:
        raise LedgerUnavailable("wake ledger bindings missing")
    cleaned, seen = [], set()
    for raw in keys or []:
        key = str(raw or "").strip().lower()
        if len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
            continue
        if key in seen:
            return {"status": "error", "error": "duplicate_key_in_request"}
        seen.add(key)
        cleaned.append(key)
    if not cleaned:
        return {"status": "error", "error": "no_valid_keys"}
    if len(cleaned) > ADMIT_MAX_DELIVERY_IDS:
        return {"status": "error", "error": "too_many_keys"}
    at = _now(now)
    conn = open_ledger(home)
    with LEDGER_LOCK:
        session = db.get_session(resolved)
        if session is None:
            return {"status": "error", "error": "session_not_found"}
        if (session.get("hidden") or session.get("archived")
                or (session.get("source") or "") in ("cron", "subagent")
                or (session.get("ended_at") is not None
                    and (session.get("end_reason") or "") != "compression")):
            return {"status": "error", "error": "session_not_allowed"}
        if _session_busy(db, resolved, at):
            return {"status": "busy", "retry_after_s": 5}
        quota = _quota(conn, resolved, at)
        if quota["session_remaining"] <= 0 or quota["profile_remaining"] <= 0:
            return {"status": "quota_exceeded", "retry_after_s": 300, "quota": quota}
        accepted, ignored, rejected = [], [], []
        claims = []
        for key in cleaned:
            prior = conn.execute(
                "SELECT batch_id, ignored, state FROM wake_consumption WHERE delivery_key = ?",
                (key,)).fetchone()
            if prior is not None:
                if prior["ignored"]:
                    ignored.append(key)
                else:
                    rejected.append({"delivery_key": key, "reason": "already_consumed",
                                     "batch_id": prior["batch_id"]})
                continue
            row = _find_report(db, resolved, key)
            if row is None or row["sch"] != 1:
                rejected.append({"delivery_key": key, "reason": "unknown_provenance"})
                continue
            if is_ignored_report(row["content"]):
                conn.execute(
                    "INSERT INTO wake_consumption(delivery_key, batch_id, session_id,"
                    " message_id, report_order, ignored, state, created_at, updated_at)"
                    " VALUES(?,?,?,NULL,?,1,'ignored',?,?)",
                    (key, None, resolved, int(row["id"]), at, at))
                ignored.append(key)
                continue
            suspect = conn.execute(
                "SELECT 1 FROM wake_batches WHERE session_id = ?"
                " AND state IN ('dispatching','accepted') AND created_at < ?"
                " AND (terminal_at IS NULL OR terminal_at > ?) LIMIT 1",
                (resolved, float(row["timestamp"]), float(row["timestamp"]))).fetchone()
            if suspect is not None:
                # A report produced INSIDE an in-flight wake run: without a
                # trustworthy causal id this source stops auto-firing (the
                # row stays visible for manual reading).
                rejected.append({"delivery_key": key, "reason": "causal_suspect"})
                continue
            claims.append((key, int(row["id"]), float(row["timestamp"])))
        if len(claims) > BATCH_MAX:
            for extra in claims[BATCH_MAX:]:
                rejected.append({"delivery_key": extra[0], "reason": "batch_overflow"})
            claims = claims[:BATCH_MAX]
        if not claims:
            conn.commit()
            return {"status": "empty", "accepted": [], "ignored": ignored,
                    "rejected": rejected, "quota": quota}
        batch_id = "wb_" + secrets.token_hex(12)
        conn.execute(
            "INSERT INTO wake_batches(batch_id, session_id, state, canonical_input,"
            " batch_keys, created_at, updated_at, owner) VALUES(?,?, 'reserved', ?, ?, ?, ?, ?)",
            (batch_id, resolved, CANONICAL_INPUT,
             json.dumps(sorted(k for k, _, _ in claims)), at, at, owner))
        for key, message_id, stamp in claims:
            conn.execute(
                "INSERT INTO wake_consumption(delivery_key, batch_id, session_id,"
                " message_id, report_order, ignored, state, created_at, updated_at)"
                " VALUES(?,?,?, ?,?,0,'consumed',?,?)",
                (key, batch_id, resolved, message_id, stamp, at, at))
            accepted.append({"delivery_key": key, "message_id": message_id})
        conn.commit()
    return {"status": "admitted", "batch_id": batch_id, "state": "reserved",
            "canonical_input": CANONICAL_INPUT, "accepted": accepted,
            "ignored": ignored, "rejected": rejected,
            "quota": _quota(conn, resolved, at)}


def gate_dispatch(home: Path, *, batch_id: str, resolved: str, input_text):
    """chat/stream entry CAS: reserved -> dispatching BEFORE the run starts.

    Returns None to let the original stream proceed, or an error dict the
    adapter renders INSTEAD of starting a second run.
    """
    conn = open_ledger(home)
    with LEDGER_LOCK:
        batch = conn.execute("SELECT * FROM wake_batches WHERE batch_id = ?",
                             (batch_id,)).fetchone()
        if batch is None:
            return {"code": "wake_batch_unknown", "status": 404}
        if batch["session_id"] != resolved:
            return {"code": "wake_batch_foreign", "status": 403}
        state = batch["state"]
        if state == "reserved":
            if input_text != batch["canonical_input"]:
                return {"code": "wake_canonical_mismatch", "status": 400}
            cur = conn.execute(
                "UPDATE wake_batches SET state='dispatching', updated_at = ?"
                " WHERE batch_id = ? AND state = 'reserved'", (_now(), batch_id))
            conn.commit()
            if cur.rowcount != 1:
                return {"code": "wake_in_flight", "status": 409,
                        "receipt": _batch_view(conn, batch_id)}
            return None
        receipt = _batch_view(conn, batch_id)
        if state in ("dispatching", "accepted"):
            return {"code": "wake_in_flight", "status": 409, "receipt": receipt}
        if state in ("uncertain-consumed", "terminal"):
            return {"code": "wake_consumed", "status": 410, "receipt": receipt}
        return {"code": "wake_released", "status": 410, "receipt": receipt}


def dispatch_failed(home: Path, batch_id: str):
    """Pre-stream HTTP rejection: the run provably never started — return
    the batch (and its claim) to the reserved state."""
    conn = open_ledger(home)
    with LEDGER_LOCK:
        conn.execute(
            "UPDATE wake_batches SET state='reserved', updated_at = ?"
            " WHERE batch_id = ? AND state='dispatching' AND run_id IS NULL",
            (_now(), batch_id))
        conn.commit()


def report(home: Path, *, batch_id: str, resolved: str, state: str, run_id=None, now=None):
    """Client-reported state transitions (CAS; illegal moves conflict)."""
    conn = open_ledger(home)
    at = _now(now)
    with LEDGER_LOCK:
        batch = conn.execute("SELECT * FROM wake_batches WHERE batch_id = ?",
                             (batch_id,)).fetchone()
        if batch is None or batch["session_id"] != resolved:
            return {"status": "error", "error": "batch_not_found"}
        current, reason = batch["state"], None
        if state == "accepted":
            if not (isinstance(run_id, str) and run_id.strip()):
                return {"status": "error", "error": "run_id_required"}
            if current == "accepted" and batch["run_id"] == run_id.strip():
                return {"status": "ok", "receipt": _batch_view(conn, batch_id)}  # idempotent
            if current != "dispatching":
                return {"status": "conflict", "state": current}
            conn.execute("UPDATE wake_batches SET state='accepted', run_id = ?, updated_at = ?"
                         " WHERE batch_id = ?", (run_id.strip(), at, batch_id))
        elif state == "terminal":
            if current not in ("dispatching", "accepted"):
                return {"status": "conflict", "state": current}
            conn.execute("UPDATE wake_batches SET state='terminal', updated_at = ?,"
                         " terminal_at = ? WHERE batch_id = ?", (at, at, batch_id))
        elif state == "uncertain":
            # Cannot prove the run never executed: consumed WITHOUT re-sending.
            if current not in ("dispatching", "accepted"):
                return {"status": "conflict", "state": current}
            conn.execute("UPDATE wake_batches SET state='uncertain-consumed', updated_at = ?,"
                         " terminal_at = ?, reason='uncertain-consumed' WHERE batch_id = ?",
                         (at, at, batch_id))
        else:
            return {"status": "error", "error": "unknown_state"}
        conn.commit()
        return {"status": "ok", "receipt": _batch_view(conn, batch_id)}


def release(home: Path, *, batch_id: str, resolved: str):
    """Only a PROVABLY undispatched batch returns its claim + quota."""
    conn = open_ledger(home)
    with LEDGER_LOCK:
        batch = conn.execute("SELECT * FROM wake_batches WHERE batch_id = ?",
                             (batch_id,)).fetchone()
        if batch is None or batch["session_id"] != resolved:
            return {"status": "error", "error": "batch_not_found"}
        if batch["state"] != "reserved" or batch["run_id"] is not None:
            return {"status": "conflict", "state": batch["state"],
                    "error": "release_requires_reserved"}
        conn.execute("DELETE FROM wake_consumption WHERE batch_id = ?", (batch_id,))
        conn.execute("UPDATE wake_batches SET state='released', updated_at = ?,"
                     " terminal_at = ?, reason='released' WHERE batch_id = ?",
                     (_now(), _now(), batch_id))
        conn.commit()
        return {"status": "ok", "receipt": _batch_view(conn, batch_id)}


def receipt(home: Path, *, batch_id: str, resolved: str):
    conn = open_ledger(home)
    with LEDGER_LOCK:
        view = _batch_view(conn, batch_id)
    if view is None or view["session_id"] != resolved:
        return {"status": "error", "error": "batch_not_found"}
    view["quota"] = _quota(conn, resolved, _now())
    return {"status": "ok", "receipt": view}


def ledger_state_for(home: Path, delivery_key: str):
    """Consumption verdict for one report, permanent across restarts."""
    conn = open_ledger(home)
    with LEDGER_LOCK:
        row = conn.execute("SELECT state, batch_id FROM wake_consumption WHERE delivery_key = ?",
                           (delivery_key,)).fetchone()
    return dict(row) if row is not None else None
