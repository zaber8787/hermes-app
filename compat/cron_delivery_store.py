"""P5-2 durable bridge store: atomic cron-report writer + pending spool/receipts.

Two stores, no fake cross-DB atomicity: the plugin spool (this file's SQLite)
is written BEFORE the SessionDB transaction, acked AFTER it. Crash between
commit and ack replays through the namespaced delivery_key and returns the OLD
row id — never a second row, never a resurrect of a deleted report. All private
SessionDB seams are reviewed-fingerprint bindings installed by compat.py; with
them absent this module refuses every write (fail-closed).
"""
from __future__ import annotations

import hashlib
import json
import logging
import sqlite3
import threading
import time
from contextlib import suppress
from pathlib import Path

log = logging.getLogger("hermes-app-compat.cron")

BRIDGE_VERSION = 1
REPORT_MAX_BYTES = 32_768
SID_MAX_LEN = 256
DRAIN_INTERVAL = 15.0
DRAIN_MAX_ATTEMPTS = 24
DRAIN_BACKOFF_BASE = 30.0
DRAIN_BACKOFF_CAP = 900.0
RESOLVE_RETRIES = 3
DISPLAY_KIND = "internal_notification"
METADATA_NS = "hermes_app_cron"
CONTENT_PREFIX = "[Cron report: {name}]\n"

# Installed by compat._install_cron_bridge after the fingerprint gate passes.
# None bindings mean the writer is NOT reviewed for this upstream: refuse.
_bindings = None
_bridge_lock = threading.RLock()
_bridges: dict[str, sqlite3.Connection] = {}


class BridgeUnavailable(RuntimeError):
    """No reviewed writer bindings for this upstream."""


class TargetPermanent(RuntimeError):
    """Target policy verdict that no retry may change (hidden/archived/ended/wrong source)."""


def configure(*, insert_sql, errors):
    """compat.py installs the reviewed SQL + error classes here; unload resets.
    The guard/params/counters helpers run off the acquired SessionDB instance
    (same reviewed class the gateway uses), which compat.py signature-gated."""
    global _bindings
    _bindings = {"insert_sql": insert_sql, "errors": errors}


def reset():
    global _bindings
    _bindings = None
    with _bridge_lock:
        for conn in _bridges.values():
            with suppress(Exception):
                conn.close()
        _bridges.clear()


def bindings_ready() -> bool:
    return _bindings is not None


def delivery_key(*, home: str, job_id: str, execution_id: str, session_id: str) -> str:
    seed = f"{home}|{job_id}|{execution_id}|{session_id}"
    return hashlib.sha256(seed.encode()).hexdigest()


def report_digest(content: str) -> str:
    return hashlib.sha256(content.encode()).hexdigest()


def bridge_file(home: Path) -> Path:
    return Path(home) / "cron_bridge.db"


def open_bridge(home: Path) -> sqlite3.Connection:
    key = str(Path(home).resolve())
    with _bridge_lock:
        conn = _bridges.get(key)
        if conn is not None:
            try:
                conn.execute("SELECT 1").fetchone()
            except sqlite3.ProgrammingError:
                # 01413 m3: a cached handle closed out of band (test fixtures,
                # operator tooling) must be replaced, never handed back dead.
                _bridges.pop(key, None)
                conn = None
            except Exception:
                pass  # busy/locked: same as HEAD — the CALLER sees the error
        if conn is None:
            Path(key).mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(bridge_file(Path(key)), check_same_thread=False, timeout=10.0)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA busy_timeout=10000")
            conn.execute("""CREATE TABLE IF NOT EXISTS pending(
                delivery_key TEXT PRIMARY KEY, home TEXT, session_id TEXT, identity TEXT,
                content TEXT, attempts INTEGER NOT NULL DEFAULT 0,
                next_retry_at REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)""")
            conn.execute("""CREATE TABLE IF NOT EXISTS receipts(
                delivery_key TEXT PRIMARY KEY, home TEXT, execution_id TEXT, status TEXT NOT NULL,
                row_id INTEGER, error TEXT, digest TEXT, session_id TEXT, created_at REAL NOT NULL,
                updated_at REAL NOT NULL)""")
            conn.execute("CREATE INDEX IF NOT EXISTS pending_due ON pending(next_retry_at)")
            conn.execute("CREATE INDEX IF NOT EXISTS receipts_exec ON receipts(execution_id)")
            conn.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
            conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('version', ?)",
                         (str(BRIDGE_VERSION),))
            from . import self_wake
            self_wake.ensure_bridge_schema(conn)
            conn.commit()
            # 01413 m3: the managed handle goes INTO the cache — an opener
            # that builds a fresh connection per call defeats reset() (which
            # closes what the cache holds) and leaks handles.
            _bridges[key] = conn
        return conn


def _self_wake_intent(conn, home, session_id, key, row_id, reason):
    """SELFWAKE: intent+receipt in ONE transaction. Registration only — the
    worker decides everything else; this never touches models or HTTP."""
    try:
        from . import self_wake
        return self_wake.on_delivered(conn, home=home, session_id=session_id,
                                       delivery_key=key, row_id=row_id, reason=reason)
    except Exception as exc:
        # An intent is a TODO row, never delivery: the receipt still commits.
        # 01413 m1: the receipt alone would tell reconciliation "this arrived
        # while self-wake was off" (history — correctly never replayed) and
        # the self-described crash-gap compensation would skip the one row it
        # CAN fix. Tag the failure inside the same transaction; reconcile
        # compensates only tagged rows, while the policy is active.
        log.warning("selfwake intent skipped: %s", type(exc).__name__)
        with suppress(Exception):
            conn.execute(
                "UPDATE receipts SET error = COALESCE(error, 'intent-failed'),"
                " updated_at = ? WHERE delivery_key = ?", (time.time(), key))
        return None


def _receipt(conn, key, home, execution_id, session_id, status, *, row_id=None, error=None,
             digest=None):
    now = time.time()
    # A committed (delivered) receipt is a terminal fact: a later queued/failed
    # observation of the same key annotates the error, it never rewrites or
    # demotes the committed state.
    conn.execute(
        """INSERT INTO receipts(delivery_key, home, execution_id, status, row_id, error, digest,
               session_id, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(delivery_key) DO UPDATE SET
               status=CASE WHEN receipts.status='delivered' THEN receipts.status
                           ELSE excluded.status END,
               row_id=COALESCE(excluded.row_id, receipts.row_id),
               error=excluded.error, digest=COALESCE(excluded.digest, receipts.digest),
               updated_at=excluded.updated_at""",
        (key, home, execution_id, status, row_id, error, digest, session_id, now, now))


def receipt_for(home: Path, execution_id: str):
    """Latest bridge receipt for one execution (durable; readable from any lane)."""
    try:
        conn = open_bridge(home)
    except Exception:
        return None
    with _bridge_lock:
        row = conn.execute(
            "SELECT status, row_id, error, session_id, delivery_key FROM receipts"
            " WHERE execution_id = ? ORDER BY updated_at DESC LIMIT 1", (execution_id,)).fetchone()
    return dict(row) if row is not None else None


def _identity_error(identity):
    if not isinstance(identity, dict):
        return "missing_delivery_identity"
    if not (isinstance(identity.get("job_id"), str) and identity["job_id"].strip()):
        return "missing_job_id"
    if not (isinstance(identity.get("execution_id"), str) and identity["execution_id"].strip()):
        return "missing_execution_id"
    return None


def deliver(*, session_id: str, content: str, identity, media_files=None, home: Path | str | None = None):
    """One report through spool-first, dedup-guaranteed delivery.

    Returns ``{"status": "delivered"|"dedup", "row_id": int}`` only after the
    SessionDB transaction committed, ``{"status": "queued", "receipt": key}``
    when the target's turn lease is live (durable pending, drainer retries), or
    ``{"status": "error", "error": code}``. Never sends anything anywhere else.
    """
    if _bindings is None:
        raise BridgeUnavailable("cron bridge writer not reviewed for this source")
    err = _identity_error(identity)
    if err:
        return {"status": "error", "error": err}
    from hermes_constants import get_hermes_home
    home = Path(home) if home else get_hermes_home()
    home = Path(home).resolve()
    job_id = str(identity["job_id"]).strip()
    execution_id = str(identity["execution_id"]).strip()
    if not isinstance(content, str) or not content.strip():
        return {"status": "error", "error": "empty_report"}
    if media_files:
        return {"status": "error", "error": "media_unsupported"}
    if "MEDIA:" in content:
        return {"status": "error", "error": "media_unsupported"}
    if len(content.encode()) > REPORT_MAX_BYTES:
        return {"status": "error", "error": "report_too_large"}
    key = delivery_key(home=str(home), job_id=job_id, execution_id=execution_id,
                       session_id=session_id)
    conn = open_bridge(home)
    now = time.time()
    with _bridge_lock:
        conn.execute(
            """INSERT INTO pending(delivery_key, home, session_id, identity, content,
                   next_retry_at, created_at, updated_at)
               VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(delivery_key) DO NOTHING""",
            (key, str(home), session_id, json.dumps(identity, sort_keys=True), content, now,
             now, now))
        conn.commit()
        existing = conn.execute("SELECT status, row_id, digest FROM receipts WHERE delivery_key = ?",
                                (key,)).fetchone()
    if existing is not None and existing["status"] == "delivered":
        if existing["digest"] == report_digest(content):
            with _bridge_lock:
                conn.execute("DELETE FROM pending WHERE delivery_key = ?", (key,))
                conn.commit()
            return {"status": "dedup", "row_id": existing["row_id"]}
        # Same key, different payload: fall through; the transaction re-checks
        # the committed row's digest and refuses to overwrite (conflict).
    outcome = _attempt(home, session_id, content, identity, key)
    if outcome["status"] in ("delivered", "dedup"):
        fresh = outcome["status"] == "delivered"
        with _bridge_lock:
            conn.execute("DELETE FROM pending WHERE delivery_key = ?", (key,))
            _receipt(conn, key, str(home), execution_id, session_id, "delivered",
                     row_id=outcome["row_id"], digest=report_digest(content))
            if fresh:
                # SELFWAKE hook: same transaction as the delivered receipt.
                _self_wake_intent(conn, str(home), session_id, key, outcome["row_id"],
                                  "delivered-direct")
            conn.commit()
        if fresh:
            from . import self_wake
            self_wake.delivered_event(home)
    elif outcome["status"] == "queued":
        with _bridge_lock:
            _receipt(conn, key, str(home), execution_id, session_id, "queued")
            conn.execute("UPDATE pending SET next_retry_at = ?, updated_at = ?"
                         " WHERE delivery_key = ?", (now + DRAIN_BACKOFF_BASE, now, key))
            conn.commit()
        outcome = dict(outcome, receipt=key)
    elif outcome.get("permanent"):
        with _bridge_lock:
            _receipt(conn, key, str(home), execution_id, session_id, "failed",
                     error=outcome["error"])
            conn.execute("DELETE FROM pending WHERE delivery_key = ?", (key,))
            conn.commit()
    else:
        with _bridge_lock:
            _receipt(conn, key, str(home), execution_id, session_id, "queued")
            conn.execute("UPDATE pending SET next_retry_at = ?, updated_at = ?"
                         " WHERE delivery_key = ?", (now + DRAIN_BACKOFF_BASE, now, key))
            conn.commit()
        outcome = dict(outcome, receipt=key)
    return outcome


def _attempt(home: Path, session_id: str, content: str, identity, key: str):
    """Resolve + single-transaction write with bounded closed-parent re-resolve."""
    from hermes_state import SessionDB  # noqa: F401 (import gate only)
    from hermes_state_registry import acquire, release_or_close
    turn_lost = _bindings["errors"]["SessionTurnLeaseLostError"]
    closed = _bindings["errors"]["CompressionSessionClosedError"]
    for _ in range(RESOLVE_RETRIES):
        try:
            db = acquire(home / "state.db")
        except Exception as exc:
            return {"status": "error", "error": f"db_unavailable:{type(exc).__name__}"}
        try:
            resolved = db.resolve_resume_session_id(session_id)
            row_id = _write_once(db, resolved, session_id, content, identity, key)
            if isinstance(row_id, tuple):
                status, row_id = row_id
                return {"status": status, "row_id": int(row_id)}
            return {"status": "delivered", "row_id": int(row_id)}
        except turn_lost:
            return {"status": "queued", "reason": "active_turn_lease"}
        except closed:
            continue  # rotation raced: re-resolve the live continuation and retry
        except TargetPermanent as exc:
            return {"status": "error", "error": str(exc), "permanent": True}
        except sqlite3.OperationalError:
            return {"status": "queued", "reason": "db_busy"}
        except sqlite3.DatabaseError:
            return {"status": "queued", "reason": "db_io"}
        finally:
            release_or_close(db)
    return {"status": "error", "error": "target_closed"}


def _write_once(db, target: str, original: str, content: str, identity, key: str):
    def report_text():
        name = identity.get("name") or identity.get("job_id")
        return CONTENT_PREFIX.format(name=name) + content

    def payload():
        return {"content": report_text(), "display_kind": DISPLAY_KIND,
                "display_metadata": {METADATA_NS: {
                    "schema": 1, "job_id": identity["job_id"],
                    "execution_id": identity["execution_id"], "delivery_key": key,
                    "original_session_id": original, "digest": report_digest(content)}}}

    def _do(conn):
        existing = conn.execute(
            """WITH RECURSIVE lineage(id) AS (
                SELECT ? UNION
                SELECT s.parent_session_id FROM sessions s JOIN lineage l ON s.id = l.id
                JOIN sessions p ON p.id = s.parent_session_id WHERE p.end_reason = 'compression'
            ) SELECT m.id, m.display_metadata FROM messages m JOIN lineage l ON m.session_id = l.id
            WHERE m.display_kind = ?
            AND json_extract(m.display_metadata, '$.hermes_app_cron.delivery_key') = ?
            LIMIT 1""", (target, DISPLAY_KIND, key)).fetchone()
        if existing is not None:
            stored = {}
            with suppress(Exception):
                stored = json.loads(existing["display_metadata"] or "{}").get(METADATA_NS, {})
            if stored and stored.get("digest") != report_digest(content):
                raise TargetPermanent("delivery_conflict")
            return ("dedup", existing["id"])
        session = conn.execute(
            "SELECT source, hidden, archived, ended_at, end_reason FROM sessions WHERE id = ?",
            (target,)).fetchone()
        if session is None:
            raise TargetPermanent("target_missing")
        # Synthetic sessions (cron transcripts, subagent children) must never
        # receive operator-targeted reports. Cross-transport sessions are fine:
        # a discord/webhook-sourced conversation can be driven from the App via
        # HTTP afterwards, and the SessionDB timeline is its single source.
        if (session["source"] or "") in ("cron", "subagent"):
            raise TargetPermanent("target_wrong_source")
        if session["hidden"]:
            raise TargetPermanent("target_hidden")
        if session["archived"]:
            raise TargetPermanent("target_archived")
        if session["ended_at"] is not None and (session["end_reason"] or "") != "compression":
            raise TargetPermanent(f"target_ended:{session['end_reason'] or 'unknown'}")
        db._check_transcript_write_guards(conn, target, None, reject_active_turn_lease=True)
        msg = payload()
        params = db._message_row_params(target, "user", msg, None, time.time(),
                                        keep_reasoning=True)
        row_id = conn.execute(_bindings["insert_sql"], params).lastrowid
        db._bump_session_counters(conn, target, 1, 0, unit=True)
        return row_id

    return db._execute_write(_do, patience_s=getattr(db, "_TRANSCRIPT_WRITE_PATIENCE_S", 15.0))


def drain_home(home: Path, *, now: float | None = None):
    """Bounded retry pass over one profile's pending spool; returns summary."""
    if _bindings is None:
        return {"skipped": "unbound"}
    conn = open_bridge(home)
    now = time.time() if now is None else now
    with _bridge_lock:
        rows = conn.execute(
            "SELECT * FROM pending WHERE next_retry_at <= ? AND attempts < ? ORDER BY"
            " next_retry_at LIMIT 32", (now, DRAIN_MAX_ATTEMPTS)).fetchall()
    delivered = deduped = queued = failed = 0
    fresh_keys = []
    for row in rows:
        identity = json.loads(row["identity"])
        outcome = _attempt(Path(row["home"]), row["session_id"], row["content"], identity,
                           row["delivery_key"])
        with _bridge_lock:
            if outcome["status"] == "delivered":
                # SELFWAKE: FRESH delivery only — dedup is a receipt echo and
                # must never inflate this count or fire a wake.
                conn.execute("DELETE FROM pending WHERE delivery_key = ?", (row["delivery_key"],))
                _receipt(conn, row["delivery_key"], row["home"], identity["execution_id"],
                         row["session_id"], "delivered", row_id=outcome["row_id"],
                         digest=report_digest(row["content"]))
                _self_wake_intent(conn, str(Path(row["home"])), row["session_id"],
                                  row["delivery_key"], outcome["row_id"], "delivered-drainer")
                delivered += 1
                fresh_keys.append(Path(row["home"]))
            elif outcome["status"] == "dedup":
                conn.execute("DELETE FROM pending WHERE delivery_key = ?", (row["delivery_key"],))
                _receipt(conn, row["delivery_key"], row["home"], identity["execution_id"],
                         row["session_id"], "delivered", row_id=outcome["row_id"],
                         digest=report_digest(row["content"]))
                deduped += 1
            elif outcome.get("permanent"):
                conn.execute("DELETE FROM pending WHERE delivery_key = ?", (row["delivery_key"],))
                _receipt(conn, row["delivery_key"], row["home"], identity["execution_id"],
                         row["session_id"], "failed", error=outcome["error"])
                failed += 1
            else:
                attempts = row["attempts"] + 1
                if attempts >= DRAIN_MAX_ATTEMPTS:
                    # 01413 m5: exhaustion must END LOUDLY. A row at the
                    # attempt cap is never selected again — leaving it in
                    # the spool with a "queued" receipt is an orphan that
                    # holds the full report text with no reader and no
                    # restart path. Close it as a readable dead-letter.
                    conn.execute("DELETE FROM pending WHERE delivery_key = ?",
                                 (row["delivery_key"],))
                    _receipt(conn, row["delivery_key"], row["home"],
                             identity["execution_id"], row["session_id"],
                             "failed", error="retry_exhausted")
                    failed += 1
                else:
                    delay = min(DRAIN_BACKOFF_CAP,
                                DRAIN_BACKOFF_BASE * (2 ** min(attempts, 5)))
                    conn.execute("UPDATE pending SET attempts = ?, next_retry_at = ?,"
                                 " updated_at = ? WHERE delivery_key = ?",
                                 (attempts, time.time() + delay,
                                  time.time(), row["delivery_key"]))
                    queued += 1
            conn.commit()
    for home_path in fresh_keys:
        from . import self_wake
        self_wake.delivered_event(home_path)
    return {"delivered": delivered, "deduped": deduped, "queued": queued, "failed": failed}
