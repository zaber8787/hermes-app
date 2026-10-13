"""Cross-process live-byte reservations for one-shot browser artifacts."""
from __future__ import annotations

import os
import sqlite3
import time
import uuid
from pathlib import Path

PRINCIPAL_BYTES = 1 << 30
GLOBAL_BYTES = 4 << 30


class QuotaExceeded(Exception):
    pass


def home() -> Path:
    configured = os.environ.get("HERMES_HOME")
    if configured:
        return Path(configured).resolve()
    from hermes_state import get_hermes_home
    return Path(get_hermes_home()).resolve()


def _limit(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
        return value if value > 0 else default
    except ValueError:
        return default


def _connect(root: Path) -> sqlite3.Connection:
    root.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(root / "artifact_live_quota.db", timeout=10.0)
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("""CREATE TABLE IF NOT EXISTS reservations(
        token TEXT PRIMARY KEY, principal TEXT NOT NULL, size_bytes INTEGER NOT NULL,
        store_root TEXT, artifact_id TEXT, expires_at REAL NOT NULL)""")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS quota_artifact"
                 " ON reservations(store_root, artifact_id)")
    conn.commit()
    return conn


def reserve(root: Path, principal: str, size: int, ttl: float) -> str:
    if not principal or size < 0:
        raise QuotaExceeded("artifact principal or size is invalid")
    conn = _connect(root)
    try:
        conn.execute("BEGIN IMMEDIATE")
        now = time.time()
        conn.execute("DELETE FROM reservations WHERE expires_at <= ?", (now,))
        principal_used = conn.execute(
            "SELECT COALESCE(SUM(size_bytes),0) FROM reservations WHERE principal = ?",
            (principal,)).fetchone()[0]
        global_used = conn.execute(
            "SELECT COALESCE(SUM(size_bytes),0) FROM reservations").fetchone()[0]
        if (principal_used + size > _limit("HERMES_ARTIFACT_PRINCIPAL_LIVE_BYTES", PRINCIPAL_BYTES)
                or global_used + size > _limit("HERMES_ARTIFACT_GLOBAL_LIVE_BYTES", GLOBAL_BYTES)):
            raise QuotaExceeded("artifact live-byte quota exceeded")
        token = uuid.uuid4().hex
        conn.execute("INSERT INTO reservations(token, principal, size_bytes, expires_at)"
                     " VALUES(?,?,?,?)", (token, principal, size,
                                          now + max(3600.0, float(ttl) + 60.0)))
        conn.commit()
        return token
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def finalize(root: Path, token: str, store_root: Path, artifact_id: str,
             expires_at: float) -> None:
    conn = _connect(root)
    try:
        conn.execute("BEGIN IMMEDIATE")
        changed = conn.execute(
            "UPDATE reservations SET store_root=?, artifact_id=?, expires_at=?"
            " WHERE token=? AND artifact_id IS NULL",
            (str(store_root.resolve()), artifact_id, expires_at, token))
        if changed.rowcount != 1:
            raise RuntimeError("artifact quota reservation was lost")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def cancel(root: Path, token: str) -> None:
    conn = _connect(root)
    try:
        conn.execute("DELETE FROM reservations WHERE token=?", (token,))
        conn.commit()
    finally:
        conn.close()


def release(root: Path, store_root: Path, artifact_id: str) -> None:
    conn = _connect(root)
    try:
        conn.execute("DELETE FROM reservations WHERE store_root=? AND artifact_id=?",
                     (str(store_root.resolve()), artifact_id))
        conn.commit()
    finally:
        conn.close()


def expire(root: Path, now: float) -> None:
    conn = _connect(root)
    try:
        conn.execute("DELETE FROM reservations WHERE expires_at <= ?", (now,))
        conn.commit()
    finally:
        conn.close()
