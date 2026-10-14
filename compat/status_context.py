"""Read-only, best-effort context facts for the app's /status dialog.

Session token totals are throughput, not context occupancy. Never substitute
them for the last prompt measurement or invent a context-window limit.
"""

from pathlib import Path
import sys


# The web service runs from hermes-agent/venv but executes serve.py in this
# repository. Python does not add the venv's parent source tree to sys.path.
_HERMES_SOURCE = Path(sys.prefix).parent
if (_HERMES_SOURCE / "hermes_state.py").is_file():
    sys.path.insert(0, str(_HERMES_SOURCE))


def _positive(value):
    return value if type(value) is int and value > 0 else None


def read_status_context(session_id: str, home: Path) -> dict | None:
    from hermes_state import SessionDB

    db = SessionDB(home / "state.db", read_only=True)
    try:
        row = db.get_session(session_id)
        if row is None:
            return None
        route = db.get_recent_session_model_route(session_id) or {}
        entry = db.gateway_routing_entry_for_session(session_id) or {}
        override = entry.get("model_override") or {}
        model = override.get("model") or route.get("model") or row.get("model")
        provider = override.get("provider") or route.get("billing_provider") or row.get("billing_provider")
        used = _positive(entry.get("last_prompt_tokens"))
        # Compression ends the parent session and starts a continuation. Only
        # the actual compression lineage counts; forks/resets are excluded by
        # the library's lineage method.
        lineage = db.get_compression_lineage(session_id)
        last_compression = None
        position = lineage.index(session_id) if session_id in lineage else 0
        if position > 0:
            parent = db.get_session(lineage[position - 1])
            if parent and parent.get("end_reason") == "compression":
                last_compression = parent.get("ended_at")
    finally:
        db.close()

    limit = None
    if model:
        try:
            from gateway.run import _resolve_gateway_model_context
            resolved = _resolve_gateway_model_context(
                model, {"provider": provider, "base_url": override.get("base_url") or ""})
            if resolved.context_source != "default":
                limit = _positive(resolved.context_length)
        except Exception:
            pass
    return {
        "model": model or None,
        "context_used_tokens": used,
        "context_limit_tokens": limit,
        "last_compression_at": last_compression,
        # The effective threshold belongs to a live ContextCompressor and is
        # not persisted in SessionDB. A config percentage may be overridden by
        # model, max output tokens and dynamic caps; exposing it would mislead.
        "compression_threshold_tokens": None,
    }
