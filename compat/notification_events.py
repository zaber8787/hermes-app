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

try:
    from . import notification_store
except ImportError:  # flat import context (unit tests)
    import notification_store

def _public_origin(value: str) -> str:
    """01413 m9: click_base composes links that land on shared devices —
    only a verified HTTPS origin (+path) is public-safe. userinfo and any
    query/fragment (where mispasted tokens and topics live) are dropped;
    an unparseable or non-HTTPS base falls back to the placeholder, never
    a secret-bearing URL."""
    from urllib.parse import urlsplit, urlunsplit
    placeholder = "https://hermes.invalid"
    try:
        parts = urlsplit(value)
        if parts.scheme != "https" or not parts.netloc:
            return placeholder
        if parts.username or parts.password:  # a credential-bearing base
            return placeholder                # is REFUSED, not laundered
        return urlunsplit(("https", parts.netloc, parts.path.rstrip("/"),
                           "", ""))
    except ValueError:
        return placeholder


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
            return _public_origin(value)
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
    if existing is not None and existing != "pending":
        return event_id, "already_" + existing
    if any(channel_seen not in ("none", channel)
           for _phase, channel_seen, _s
           in notification_store.sent_phases(store, event_id)):
        # a config change must never re-route an already-claimed delivery to
        # a different channel (R6: claims survive reconfiguration). A DIFFERENT
        # phase on the SAME channel is a legitimate later stage (initial ->
        # reminder), not a re-route (01412 audit M4).
        return event_id, "already_claimed_other_channel"
    delivery_id = _delivery_id(event_id, phase, channel)
    if channel == "browser" and publish is None:
        # 01412 M5: the server records a PENDING INTENT only. The one device/
        # tab that claims it shows the alert; a server-side claim would make
        # every device claim answer already_claimed and the whole browser
        # path unusable. The ledger still keeps the claim race honest.
        verdict, _assigned = notification_store.queue_delivery(
            store, event_id=event_id, phase=phase, channel=channel,
            delivery_id=delivery_id)
        return event_id, verdict
    verdict, assigned = notification_store.claim_delivery(
        store, event_id=event_id, phase=phase, channel=channel,
        delivery_id=delivery_id, device_id="server")
    if verdict != "claimed":
        return event_id, "already_claimed"
    outcome = "unknown"
    if publish is not None:
        try:
            # publish() proves a LOCAL ACCEPT (enqueue into the transport's
            # own queue), NEVER a device delivery — an enqueue is honestly
            # recorded as "enqueued", not "sent" (01412 audit m1).
            outcome = "enqueued" if publish() else "failed"
        except Exception:
            outcome = "unknown"
    notification_store.note_delivery(store, delivery_id=assigned,
                                     outcome=outcome, channel=channel)
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


# A locally-accepted transport answer counts as dispatched for the gate; an
# enqueue is honest ("enqueued"), never dressed up as "sent" (01412 m1).
PUBLISH_OK = frozenset({"sent", "already_sent", "enqueued", "already_enqueued",
                        "queued"})


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
            return True, outcome in PUBLISH_OK
        event_id, outcome = deliver(reg, kind="approval_request",
                                    payload={"summary": "approval"},
                                    phase="initial", publish=meta["publish"], **common)
        return True, outcome in PUBLISH_OK
    return gate


SUMMARY_BYTE_CAP = 240


def _redact_summary(text) -> str:
    """01412 m2: a stored summary crosses the SAME approval redaction seam
    (core error redactor, then the credential whitelist) and a UTF-8 byte cap
    that never splits a code point. Raw run output must never hit the ledger."""
    raw = str(text or "")
    try:
        try:
            from . import approval_inbox
        except ImportError:  # flat import context (unit tests)
            import approval_inbox
        raw = approval_inbox._redact_text(raw, cap=SUMMARY_BYTE_CAP)
        raw = approval_inbox._REDACTION_RE.sub(approval_inbox._REDACTION, raw)
    except Exception:
        pass
    try:
        try:
            from .ntfy_notify import utf8_cut
        except ImportError:
            from ntfy_notify import utf8_cut
        return utf8_cut(raw, SUMMARY_BYTE_CAP)
    except Exception:
        return raw.encode("utf-8", "replace")[:SUMMARY_BYTE_CAP].decode(
            "utf-8", "ignore")


def terminal_event(reg, *, owner_scope, run_id, sid, status, summary=""):
    kind = {"completed": "completed", "failed": "failed",
            "cancelled": "cancelled", "interrupted": "interrupted"}[status]
    return deliver(reg, owner_scope=owner_scope, run_id=run_id, sid=sid,
                   kind=kind, source_id="terminal",
                   payload={"summary": _redact_summary(summary)})


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
