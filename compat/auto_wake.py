"""APPWAKE contract constants + minimal cron provenance (server authority).

The messages GET projection may expose ONLY this verified identity — never
raw display_metadata. A report row qualifies when the bridge wrote a valid
hermes_app_cron block; text or display_kind alone never proves provenance.
Batch B extends this module with the durable consumption ledger and the
capability-gated admission/receipt contract.
"""
from __future__ import annotations

import hashlib
import json

WAKE_SCHEMA = 1
METADATA_NS = "hermes_app_cron"
DISPLAY_KIND = "internal_notification"
CONTENT_PREFIX = "[Cron report: "
CANONICAL_INPUT = "請讀取新到的排程報告並簡短回覆。"
SESSION_WAKE_LIMIT = 6
PROFILE_WAKE_LIMIT = 12
QUOTA_WINDOW_SECONDS = 3600.0
BATCH_MAX = 10
LEDGER_VERSION = 1


def provenance_of(row) -> dict | None:
    """Server-verified minimal cron identity for ONE message row, or None.

    `row` is the raw DB row mapping (role, display_kind, display_metadata).
    Validation is exact: role=user, display_kind=internal_notification, a
    dict block with schema==1 and three non-empty strings, the delivery key
    matching the digest shape the bridge writes. Anything else exposes
    NOTHING.
    """
    try:
        if (row.get("role"), row.get("display_kind")) != ("user", DISPLAY_KIND):
            return None
        raw = row.get("display_metadata")
        meta = json.loads(raw) if isinstance(raw, str) else (raw or {})
        block = meta.get(METADATA_NS) if isinstance(meta, dict) else None
        if not isinstance(block, dict) or block.get("schema") != WAKE_SCHEMA:
            return None
        job_id = block.get("job_id")
        execution_id = block.get("execution_id")
        key = block.get("delivery_key")
        if not all(isinstance(x, str) and x.strip()
                   for x in (job_id, execution_id, key)):
            return None
        if len(key) != 64 or any(c not in "0123456789abcdef" for c in key.lower()):
            return None
        return {"schema": WAKE_SCHEMA, "job_id": job_id.strip(),
                "execution_id": execution_id.strip(), "delivery_key": key.lower()}
    except Exception:
        return None


def report_body(content: str) -> str:
    """Bridge body minus the fixed name prefix (whole-equality checks only)."""
    if not isinstance(content, str):
        return ""
    if content.startswith(CONTENT_PREFIX):
        newline = content.find("]\n")
        if newline != -1:
            return content[newline + 2:].strip()
    return content.strip()


def is_ignored_report(content: str) -> bool:
    """Empty or EXACTLY NO_REPLY/HEARTBEAT_OK after prefix removal —
    ignored-consumed. A report merely CONTAINING the string elsewhere is
    never killed."""
    body = report_body(content)
    return body == "" or body in ("NO_REPLY", "HEARTBEAT_OK")


def ledger_key(home: str, delivery_key: str) -> str:
    """Consumption namespace: profile home + stable delivery_key — NOT
    credentials, so an API-key rotation can never rebuild the ledger."""
    return hashlib.sha256(f"{home}|{delivery_key}".encode()).hexdigest()
