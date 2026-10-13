"""R1: a late accepted report cannot demote a concurrently terminal batch."""
from __future__ import annotations

import multiprocessing
import os
import sqlite3
import time
from pathlib import Path


def _report(home: str, state: str, barrier, terminal_done, out):
    from .wake import wake_ref
    store = wake_ref()["store"]
    conn = sqlite3.connect(Path(home) / "wake_ledger.db", timeout=10)
    conn.row_factory = sqlite3.Row

    class Connection:
        first_read = True

        def execute(self, sql, params=()):
            cursor = conn.execute(sql, params)
            if sql.startswith("SELECT * FROM wake_batches") and self.first_read:
                self.first_read = False
                barrier.wait(timeout=10)
                if state == "accepted" and not terminal_done.wait(timeout=10):
                    raise RuntimeError("terminal report never committed")
            return cursor

        def commit(self):
            conn.commit()
            if state == "terminal":
                terminal_done.set()

        def rollback(self):
            conn.rollback()

    store.open_ledger = lambda _home: Connection()
    try:
        result = store.report(Path(home), batch_id="race-batch", resolved="race-session",
                              state=state, run_id="race-run" if state == "accepted" else None)
        out.put((state, result["status"]))
    finally:
        conn.close()


async def case_wake_report_race(args, server, check):
    from .wake import wake_ref
    home = Path(os.environ["HERMES_HOME"])
    store = wake_ref()["store"]
    ledger = store.open_ledger(home)
    ledger.execute(
        "INSERT INTO wake_batches(batch_id, session_id, state, canonical_input,"
        " batch_keys, created_at, updated_at) VALUES(?,?,?,?,?,?,?)",
        ("race-batch", "race-session", "dispatching", "wake", "[]",
         time.time(), time.time()))
    ledger.commit()

    context = multiprocessing.get_context("fork")
    barrier = context.Barrier(2)
    terminal_done = context.Event()
    out = context.Queue()
    processes = [context.Process(target=_report,
                                 args=(str(home), state, barrier, terminal_done, out))
                 for state in ("accepted", "terminal")]
    try:
        for process in processes:
            process.start()
        for process in processes:
            process.join(timeout=15)
        check(all(process.exitcode == 0 for process in processes),
              "both cross-process report calls settle")
        statuses = dict(out.get(timeout=2) for _ in processes)
        row = sqlite3.connect(home / "wake_ledger.db").execute(
            "SELECT state, terminal_at FROM wake_batches WHERE batch_id='race-batch'").fetchone()
        check(row[0] == "terminal" and row[1] is not None
              and statuses == {"accepted": "conflict", "terminal": "ok"},
              "late accepted report cannot overwrite the terminal receipt")
    finally:
        for process in processes:
            if process.is_alive():
                process.terminate()
                process.join(timeout=2)
