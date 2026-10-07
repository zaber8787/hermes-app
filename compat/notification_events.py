"""Notification events policy layer (STEERWEB R6): ONE OS-notification exit.

Rules encoded here:
* the same semantic event gets ONE ntfy publish (ledger-claimed before the
  output is called; reconnects/restarts never re-derive a different id);
* configured ntfy owns the system channel; browser delivery is the explicit
  desktop fallback ONLY when no ntfy is configured, gated by a one-time server
  claim so two tabs/devices cannot both alert;
* a READ event stops later reminders and other devices' browser alerts, but
  read never means approve and never touches an approval deadline;
* cancelled/interrupted terminals are recorded and never pushed;
* a configuration change never re-routes an already-claimed delivery.
"""
from __future__ import annotations

import hashlib
import uuid

from . import notification_store

def _click_base() -> str:
    # Config-owned public entry (app_compat.notification_events.click_base):
    # the server deployment's tailnet/host never belongs in a shared build.
    try:
        from hermes_cli.config import get_config_path
        from utils import fast_safe_load
        with open(get_config_path(), encoding="utf-8-sig") as handle:
            raw = fast_safe_load(handle)
        block = (((raw or {}).get("app_compat") or {}).get("notification_events") or {})
        value = str(block.get("click_base") or "").strip()
        if value:
            return value.rstrip("/")
    except Exception:
        pass
    return "https://hermes.invalid"

_capability_on = False
_registry = None


def run_link(*, sid=None, run_id=None, event_id=None, request_id=None) -> str:
    """Canonical HTTPS deep link (R7); NEVER a key, topic or other secret."""
    from urllib.parse import quote
    parts = []
    if sid:
        parts.append("session=" + quote(str(sid), safe=""))
    if run_id:
        parts.append("run=" + quote(str(run_id), safe=""))
    if event_id:
        parts.append("event=" + quote(str(event_id), safe=""))
    if request_id:
        parts.append("request=" + quote(str(request_id), safe=""))
    return _click_base() + "/#/chat" + ("?" + "&".join(parts) if parts else "")


def set_capability(enabled: bool) -> None:
    global _capability_on
    _capability_on = bool(enabled)


def capability_enabled() -> bool:
    return _capability_on


def open_ledger(state, home_resolver=None, settings=None):
    global _registry
    reg = state.get("notification_events")
    if reg is None:
        reg = {
            "home_resolver": home_resolver,
            "settings": settings or (lambda: None),
            "watchers": {},      # (owner_scope, run_id) -> True (steer.ready opt-in)
            "closed": False,
        }
        state["notification_events"] = reg
    reg["settings"] = settings or reg["settings"]
    reg["closed"] = False
    _registry = reg
    return reg


def registry():
    return _registry


def home_of(reg):
    resolver = reg.get("home_resolver")
    if resolver is not None:
        return resolver()
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def system_channel(reg) -> str:
    settings = reg["settings"]()
    return "ntfy" if settings else "browser"


def _delivery_id(event_id: str, phase: str, channel: str) -> str:
    return hashlib.sha256(f"{event_id}\0{phase}\0{channel}".encode()).hexdigest()[:24]


def deliver(reg, *, owner_scope, run_id, sid, kind, source_id, payload,
            phase="initial", publish=None, channel=None):
    """Record the event, claim the transport delivery BEFORE the output, and
    call publish exactly once for the semantic event+phase. publish returns
    True on locally-accepted enqueue; False is recorded as failed; an
    indeterminate result is recorded as unknown and NEVER re-pushed elsewhere."""
    store = home_of(reg)
    event_id, created = notification_store.record_event(
        store, owner_scope=owner_scope, run_id=run_id, sid=sid, kind=kind,
        source_id=source_id, payload=payload)
    channel = channel or system_channel(reg)
    if kind in ("cancelled", "interrupted", "steer_ready"):
        # recorded, surfaced through the events inbox; never an OS push
        return event_id, "recorded"
    if notification_store.is_read(store, event_id):
        return event_id, "suppressed_read"
    if publish is None and channel == "ntfy" and kind in ("completed", "failed"):
        publish = _ntfy_publish(reg, kind,
                                click=run_link(sid=sid, run_id=run_id, event_id=event_id))
    existing = notification_store.delivery_state(store, event_id, phase, channel)
    if existing is not None:
        return event_id, "already_" + existing
    if any(channel_seen != "none" for _phase, channel_seen, _s
           in notification_store.sent_phases(store, event_id)):
        # a config change must never re-route an already-claimed delivery to
        # a different channel (R6: claims survive reconfiguration).
        return event_id, "already_claimed_other_channel"
    delivery_id = _delivery_id(event_id, phase, channel)
    verdict, assigned = notification_store.claim_delivery(
        store, event_id=event_id, phase=phase, channel=channel,
        delivery_id=delivery_id, device_id="server")
    if verdict != "claimed":
        return event_id, "already_claimed"
    if channel == "browser" and publish is None:
        # queued for a single desktop tab/device to claim; the ledger keeps the
        # claim state, no server-side publish attempt is recorded.
        return event_id, "queued"
    outcome = "unknown"
    if publish is not None:
        try:
            outcome = "sent" if publish() else "failed"
        except Exception:
            outcome = "unknown"
    notification_store.note_delivery(store, delivery_id=assigned,
                                     outcome="sent" if outcome == "sent" else
                                     ("failed" if outcome == "failed" else "unknown"),
                                     channel=channel)
    return event_id, outcome


def reminder_allowed(reg, *, owner_scope, run_id, request_id, pending: bool) -> bool:
    """A reminder fires only while the request is still pending, the semantic
    approval event is UNREAD somewhere-not, and the reminder phase was never
    claimed. Read converges reminders across devices (R6)."""
    if not pending:
        return False
    store = home_of(reg)
    event_id = notification_store.event_id_for(owner_scope, run_id,
                                               "approval_request", request_id)
    if notification_store.is_read(store, event_id):
        return False
    if notification_store.delivery_state(store, event_id, "reminder",
                                         system_channel(reg)) is not None:
        return False
    return True


def _owner_of(meta):
    entry = meta.get("entry") or {}
    if entry.get("owner_scope"):
        return entry["owner_scope"]
    try:
        return entry["adapter"]._run_owners.get(entry.get("run_id"))
    except Exception:
        return None


def approval_initial_hook(reg):
    """Gate consumed by approval_push.publish: (handled, ok). While the ledger
    is live it owns the one-publish-per-semantic-event rule and the read-aware
    reminder policy; with the capability off NOTHING is intercepted."""
    def gate(kind, meta):
        if not _capability_on or reg.get("closed"):
            return False, False
        entry = meta.get("entry") or {}
        scope = _owner_of(meta) or ""
        common = dict(owner_scope=scope, run_id=entry.get("run_id"),
                      sid=entry.get("session_id"), source_id=entry.get("request_id"))
        if kind == "reminder":
            if not reminder_allowed(reg, owner_scope=scope,
                                    run_id=entry.get("run_id"),
                                    request_id=entry.get("request_id"),
                                    pending=bool(meta.get("pending"))):
                return True, False
            event_id, outcome = deliver(reg, kind="approval_request",
                                        payload={"summary": "reminder"},
                                        phase="reminder", publish=meta["publish"], **common)
            return True, outcome in ("sent", "already_sent", "queued")
        event_id, outcome = deliver(reg, kind="approval_request",
                                    payload={"summary": "approval"},
                                    phase="initial", publish=meta["publish"], **common)
        return True, outcome in ("sent", "already_sent", "queued")
    return gate


def terminal_event(reg, *, owner_scope, run_id, sid, status, summary=""):
    kind = {"completed": "completed", "failed": "failed",
            "cancelled": "cancelled", "interrupted": "interrupted"}[status]
    return deliver(reg, owner_scope=owner_scope, run_id=run_id, sid=sid,
                   kind=kind, source_id="terminal",
                   payload={"summary": str(summary)[:240]})


def _ntfy_publish(reg, kind, click=None):
    def publish():
        settings = reg["settings"]()
        if not settings:
            return False
        from . import ntfy_notify
        title = {"completed": "Hermes: run completed", "failed": "Hermes: run failed"}[kind]
        return ntfy_notify.publish_json(
            settings[0], settings[1], title, "Open the Hermes app for details.",
            priority="high" if kind == "failed" else "default",
            tags=["done" if kind == "completed" else "warning"], click=click)
    return publish


def steer_ready(reg, *, owner_scope, run_id, sid):
    if not _capability_on:
        return
    if not reg["watchers"].get((owner_scope, run_id)):
        return  # only runs the user explicitly opted into
    deliver(reg, owner_scope=owner_scope, run_id=run_id, sid=sid,
            kind="steer_ready", source_id="ready", payload={}, channel="none")


def watch(reg, *, owner_scope, run_id, on: bool):
    if on:
        reg["watchers"][(owner_scope, run_id)] = True
    else:
        reg["watchers"].pop((owner_scope, run_id), None)
    return on


def unwatch_run(reg, adapter_key_run):
    reg["watchers"].pop(adapter_key_run, None)
