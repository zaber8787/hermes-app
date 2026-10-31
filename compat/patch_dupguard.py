"""DUPGUARD (2026-10-25): message double-write guard, installed by compat.

Symptom: on the device that SENT a turn, the step list showed every tool
step twice; other devices viewing the same session were clean. The server
rows themselves carried the same (session_id, tool_call_id) twice — an
upstream replay path re-persists whole assistant+tool pairs (correlated
with agent.message_sanitization's "Normalized provider-minted parallel
tool-call ids for replay compatibility" warnings). The app's live-vs-
history tool merge refuses to match ANY row whose call id appears more
than once (ambiguity proves nothing), so the sending device's live
transcript rows stop being excluded and render next to the durable pair.

Guard = two BEFORE INSERT triggers with RAISE(IGNORE), installed
idempotently on every load of this plugin:
  app_dupguard_tool_row      one durable row per (session, tool_call_id)
  app_dupguard_tool_caller   one empty-content assistant row per exact
                             tool_calls JSON per session
Both conditions are replay-only paths: legitimate writers never re-insert
the same call id, and provider call ids are uuid-minted, so a byte-equal
tool_calls JSON is replay, not a coincidence. The triggers make the core
bug harmless until upstream lands a fix; when it does, these stay inert.

A plain sqlite3 connect is deliberate: one short WAL transaction, no
foreign lock held across await, safe from any thread, and it works before
SessionDB is even constructed.
"""
from __future__ import annotations

import sqlite3

_TRIGGERS = """
CREATE TRIGGER IF NOT EXISTS app_dupguard_tool_row
BEFORE INSERT ON messages
WHEN NEW.role = 'tool' AND NEW.tool_call_id IS NOT NULL AND NEW.tool_call_id <> ''
BEGIN
  SELECT RAISE(IGNORE) WHERE EXISTS (
    SELECT 1 FROM messages m
    WHERE m.session_id = NEW.session_id AND m.tool_call_id = NEW.tool_call_id
      AND m.role = 'tool');
END;
CREATE TRIGGER IF NOT EXISTS app_dupguard_tool_caller
BEFORE INSERT ON messages
WHEN NEW.role = 'assistant' AND NEW.tool_calls IS NOT NULL
     AND coalesce(NEW.content, '') = ''
BEGIN
  SELECT RAISE(IGNORE) WHERE EXISTS (
    SELECT 1 FROM messages m
    WHERE m.session_id = NEW.session_id AND m.role = 'assistant'
      AND m.tool_calls = NEW.tool_calls);
END;
"""


def install(state_db_path, log) -> None:
    """Verify-or-install both triggers on the given state.db path."""
    con = sqlite3.connect(str(state_db_path), timeout=15.0)
    try:
        names = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='trigger' "
            "AND name LIKE 'app_dupguard_%'")}
        con.executescript(_TRIGGERS)
        con.commit()
        after = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='trigger' "
            "AND name LIKE 'app_dupguard_%'")}
        if not {"app_dupguard_tool_row", "app_dupguard_tool_caller"} <= after:
            raise RuntimeError(f"dupguard triggers missing after install: {after}")
        log.info("DUPGUARD: message double-write triggers active%s",
                 "" if names == after else f" (newly installed: {sorted(after - names)})")
    finally:
        con.close()
