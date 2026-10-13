#!/usr/bin/env python3
"""Local Hermes admin entry for a single audited self-wake chain release.

This is an operator command, not a network endpoint. It requires an exact
session and the observed fire count; omitted --apply performs a read-only
preview. Never use this command from a probe against a production HOME.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compat.self_wake import chain_release  # noqa: E402


def snapshot(home: Path, session: str) -> dict:
    path = home / "wake_ledger.db"
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        db.row_factory = sqlite3.Row
        row = db.execute(
            "SELECT fires, fails, fused, last_fire_at FROM selfwake_chain"
            " WHERE session_id = ?", (session,)).fetchone()
        audit = db.execute(
            "SELECT seq FROM selfwake_audit WHERE session_resolved = ?"
            " AND phase = 'chain-reset' AND reason = 'admin'"
            " ORDER BY seq DESC LIMIT 1", (session,)).fetchone()
    return {"chain": dict(row) if row else None,
            "last_admin_reset_seq": audit["seq"] if audit else None}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--expect-fires", type=int, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if not args.home.is_absolute() or not args.session.strip() or args.expect_fires < 0:
        parser.error("home must be absolute, session nonempty, fires nonnegative")
    before = snapshot(args.home, args.session)
    if before["chain"] is None:
        parser.error("chain row does not exist")
    if before["chain"]["fires"] != args.expect_fires:
        parser.error("chain fire count differs from --expect-fires")
    applied = False
    if args.apply:
        applied = chain_release(args.home, args.session, args.expect_fires)
    after = snapshot(args.home, args.session)
    print(json.dumps({"session": args.session, "before": before,
                      "after": after, "applied": applied}, sort_keys=True))
    return 0 if not args.apply or applied else 1


if __name__ == "__main__":
    raise SystemExit(main())
