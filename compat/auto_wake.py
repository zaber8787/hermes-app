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
    """Bridge body minus the fixed name prefix and cron header block
    (``[Cron report: x]``…dashes line); raw-delivery shape supported too."""
    if not isinstance(content, str):
        return ""
    import re
    if content.startswith(CONTENT_PREFIX):
        newline = content.find("]\n")
        if newline != -1:
            content = content[newline + 2:]
        # cron header block: everything up to the dashed separator line
        content = re.sub(r'(?s)^(.*?\n)?-{6,}\n', '', content, count=1)
    return content.strip()


CRON_FOOTER_RE = (r'\n*To stop or manage this job, send me a new message '
                  r'\(e\.g\. "stop reminder [^"]+"\)\.?\s*$')
# observed: after the strict-alternation merge the stored survivor row may
# carry the fixed wake input appended — strip it too, else a heartbeat that
# was once woken on stays "eligible" forever
WAKE_INPUT_RE = r'\n*請讀取新到的排程報告並簡短回覆。\s*$'


def is_ignored_report(content: str) -> bool:
    """Ignore exact sentinels and a packaged idle heartbeat from the worker.

    Prefix/footer/merged wake text are removed first. A substantive report
    merely mentioning a sentinel inside its body remains eligible.
    """
    import re
    body = normalized_report_body(content)
    if body == "" or body in ("NO_REPLY", "HEARTBEAT_OK"):
        return True
    # Real worker-done-watch row 42386: an idle/no-new-items explanation
    # precedes the final standalone heartbeat sentinel. A mere mention in a
    # substantive report still does not suppress that report.
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    if lines and lines[-1] == "HEARTBEAT_OK":
        preface = "\n".join(lines[:-1])
        if (re.search(r"\bidle\b", preface, re.IGNORECASE)
                and re.search(r"無新事項|no new (?:items|work)|nothing pending",
                              preface, re.IGNORECASE)):
            return True
    return False


def normalized_report_body(content: str) -> str:
    """Stable source body across cron headers, footers and merge wake text."""
    import re
    body = report_body(content).replace("\r\n", "\n")
    # Either suffix may wrap the other (and the merge may append twice).
    while True:
        previous = body
        body = re.sub(WAKE_INPUT_RE, "", body).rstrip()
        body = re.sub(CRON_FOOTER_RE, "", body).rstrip()
        if body == previous:
            return body.strip()


def ledger_key(home: str, delivery_key: str) -> str:
    """Consumption namespace: profile home + stable delivery_key — NOT
    credentials, so an API-key rotation can never rebuild the ledger."""
    return hashlib.sha256(f"{home}|{delivery_key}".encode()).hexdigest()
