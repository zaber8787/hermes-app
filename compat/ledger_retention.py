"""Transactional, bounded archive of expired terminal ledger rows.

Each ledger keeps an append-only JSON archive in its own SQLite transaction;
live cursors and in-progress rows are untouched. Existing schemas need no
version bump and an interrupted pass rolls back archive and deletion together.
"""
from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

TTL_SECONDS = 90 * 86400
BATCH = 100
ARCHIVE_SQL = """CREATE TABLE IF NOT EXISTS retention_archive(
    source_table TEXT NOT NULL, record_key TEXT NOT NULL,
    archived_at REAL NOT NULL, payload TEXT NOT NULL,
    PRIMARY KEY(source_table, record_key))"""


def _archive(conn, table: str, key: str, rows, now: float):
    for row in rows:
        conn.execute("INSERT OR IGNORE INTO retention_archive VALUES(?,?,?,?)",
                     (table, str(row[key]), now, json.dumps(dict(row), sort_keys=True)))


def _children(conn, table: str, key: str, parent_field: str, parent_ids, now: float):
    if not parent_ids:
        return
    marks = ",".join("?" for _ in parent_ids)
    rows = conn.execute(f"SELECT * FROM {table} WHERE {parent_field} IN ({marks})",
                        parent_ids).fetchall()
    if table == "read_events":
        for row in rows:
            conn.execute("INSERT OR IGNORE INTO retention_archive VALUES(?,?,?,?)",
                         (table, f"{row['event_id']}:{row['reader']}", now,
                          json.dumps(dict(row), sort_keys=True)))
    else:
        _archive(conn, table, key, rows, now)
    conn.execute(f"DELETE FROM {table} WHERE {parent_field} IN ({marks})", parent_ids)


def _prune(path: Path, kind: str, cutoff: float, now: float) -> int:
    if not path.is_file():
        return 0
    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA busy_timeout=10000")
        conn.execute("BEGIN IMMEDIATE")
        conn.execute(ARCHIVE_SQL)
        if kind == "notification":
            rows = conn.execute(
                "SELECT * FROM events e WHERE e.read_at IS NOT NULL AND e.read_at < ?"
                " AND NOT EXISTS(SELECT 1 FROM deliveries d WHERE d.event_id=e.event_id"
                " AND d.state NOT IN ('shown','sent','failed','unknown'))"
                " LIMIT ?", (cutoff, BATCH)).fetchall()
            ids = [r["event_id"] for r in rows]
            _children(conn, "deliveries", "delivery_id", "event_id", ids, now)
            _children(conn, "read_events", "event_id", "event_id", ids, now)
            # Multiple readers share event_id; preserve each acknowledgement
            # under a unique archive key before removing the live rows.
            _archive(conn, "events", "event_id", rows, now)
            if ids:
                marks = ",".join("?" for _ in ids)
                conn.execute(f"DELETE FROM events WHERE event_id IN ({marks})", ids)
        elif kind == "wake":
            rows = conn.execute(
                "SELECT * FROM wake_batches WHERE state IN"
                " ('terminal','uncertain-consumed','released')"
                " AND terminal_at IS NOT NULL AND terminal_at < ? LIMIT ?",
                (cutoff, BATCH)).fetchall()
            ids = [r["batch_id"] for r in rows]
            _children(conn, "wake_consumption", "delivery_key", "batch_id", ids, now)
            _archive(conn, "wake_batches", "batch_id", rows, now)
            if ids:
                marks = ",".join("?" for _ in ids)
                conn.execute(f"DELETE FROM wake_batches WHERE batch_id IN ({marks})", ids)
        elif kind == "cron":
            rows = conn.execute(
                "SELECT * FROM receipts r WHERE r.status IN ('delivered','failed')"
                " AND r.updated_at < ? AND NOT EXISTS"
                " (SELECT 1 FROM pending p WHERE p.delivery_key=r.delivery_key)"
                " LIMIT ?", (cutoff, BATCH)).fetchall()
            _archive(conn, "receipts", "delivery_key", rows, now)
            ids = [r["delivery_key"] for r in rows]
            if ids:
                marks = ",".join("?" for _ in ids)
                conn.execute(f"DELETE FROM receipts WHERE delivery_key IN ({marks})", ids)
        else:
            raise ValueError(kind)
        conn.commit()
        return len(rows)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def prune_home(home: Path, *, now: float | None = None) -> dict[str, int]:
    home = Path(home)
    now = time.time() if now is None else now
    cutoff = now - TTL_SECONDS
    return {kind: _prune(home / name, kind, cutoff, now)
            for kind, name in (("notification", "notification-events.sqlite"),
                               ("wake", "wake_ledger.db"),
                               ("cron", "cron_bridge.db"))}
