"""APPROVALPUSH R4/R5: immediate approval notifications and reminder lifecycle.

The dispatcher is the ONLY approval push exit while the inbox capability is
enabled (the legacy detached-only exit stays for rollback). One initial
notification per exact request the moment the native pending entry is
confirmed — viewer state is irrelevant; one reminder near the deadline. The
server never claims delivery: enqueue accepted/dropped and the single send
attempt's sanitized outcome are counters on the registry.

Timers are threading.Timer on the monotonic stamp captured at request time:
reconnects, config re-reads, duplicate captures and wall-clock jumps can never
reset a deadline. A fired reminder revalidates everything (capability, phase,
exact queue membership, run not terminal, >=1 second left) before publishing —
an expired card never broadcasts "still approvable".
"""
from __future__ import annotations

import logging
import threading
import time

log = logging.getLogger("hermes-app-compat.approval_push")

TITLE = {"zh-TW": "Hermes 待核准｜{summary}｜{run}",
         "en": "Hermes approval | {summary} | {run}"}
TITLE_REMINDER = {"zh-TW": "Hermes 核准即將逾時｜{summary}｜{run}",
                  "en": "Hermes approval expiring | {summary} | {run}"}
CHOICE_LABELS = {"zh-TW": {"once": "允許一次", "session": "本次對話都允許",
                           "always": "一律允許", "deny": "拒絕"},
                 "en": {"once": "Allow once", "session": "Allow for this conversation",
                        "always": "Always allow", "deny": "Deny"}}
STRINGS = {
    "zh-TW": {"choices": "可選：{choices}", "remaining": "約剩 {seconds} 秒",
              "policy": "未回覆將不執行此動作", "open": "打開 Hermes App 核准"},
    "en": {"choices": "Choices: {choices}", "remaining": "About {seconds} seconds left",
           "policy": "This action will not run without a response",
           "open": "Open Hermes App to respond"},
}
BODY_BYTES = 1900
TITLE_BYTES = 120
SUMMARY_CHARS = 60
DESCRIPTION_CHARS = 160
REMINDER_LEAD_CAP = 60.0     # remind at created + T - min(60, T/2)
RUN_ID_SHORT_CHARS = 8
TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled", "interrupted"})


def normalize_locale(value) -> str:
    text = str(value or "").strip().lower()
    return "en" if text.startswith("en") else "zh-TW"


def reminder_delay(timeout):
    """Delay to the one near-timeout reminder; None means never notify."""
    try:
        T = float(timeout)
    except (TypeError, ValueError):
        return None
    if T <= 0:
        return None
    return max(0.0, T - min(REMINDER_LEAD_CAP, T / 2.0))


def run_short(run_id) -> str:
    text = str(run_id or "")
    if text.startswith("run_"):
        text = text[4:]
    return text[:RUN_ID_SHORT_CHARS] or "?"


def sanitize_inline(text, cap) -> str:
    flat = " ".join(str(text or "").split())
    return flat[:cap]


def compose(entry, locale="zh-TW", phase="initial", clock=time.monotonic):
    """(title, body) for one exact request. Both sides are desensitized
    previews; the raw command and the topic never appear (R4)."""
    locale = normalize_locale(locale)
    payload = entry["payload"]
    summary = sanitize_inline(payload.get("description") or payload.get("pattern_key"),
                              SUMMARY_CHARS) or "action"
    short = run_short(entry["run_id"])
    template = (TITLE if phase == "initial" else TITLE_REMINDER)[locale]
    title = template.format(summary=summary, run=short)
    remaining = max(0, int(entry["created_mono"] + entry["timeout"] - clock()) + 1)
    strings, labels = STRINGS[locale], CHOICE_LABELS[locale]
    choices = "、".join(labels.get(choice, choice) for choice in payload.get("choices", [])) \
        if locale == "zh-TW" else ", ".join(labels.get(choice, choice)
                                            for choice in payload.get("choices", []))
    tail = "\n".join([strings["choices"].format(choices=choices),
                      strings["remaining"].format(seconds=remaining),
                      strings["policy"], strings["open"]])
    try:
        from . import ntfy_notify
    except ImportError:
        import ntfy_notify
    # Priority order: summary and the tail (choices + seconds) must survive an
    # overlong description, so the description absorbs the first cut.
    for description_cap in (DESCRIPTION_CHARS, 80, 40, 0):
        parts = [summary]
        cut = sanitize_inline(payload.get("description"), description_cap)
        if cut:
            parts.append(cut)
        body = "\n".join(parts + [tail])
        if len(body.encode("utf-8")) <= BODY_BYTES:
            break
    return ntfy_notify.utf8_cut(title, TITLE_BYTES), ntfy_notify.utf8_cut(body, BODY_BYTES)


def attach(inbox, *, ntfy=None, clock=time.monotonic, timers=None, settings=None,
           queue_ids=None, timeout=None, status_ok=None):
    """Build the dispatcher and install it on the registry. Every dependency is
    injectable so the P-family tests run without core, sockets or a hub. In
    production compat supplies the profile-aware real bindings and a status_ok
    that also honours the capability kill switch, so a disabled unit publishes
    no in-flight reminders either."""
    if ntfy is None:
        try:
            from . import ntfy_notify as ntfy
        except ImportError:  # flat import context (unit tests)
            import ntfy_notify as ntfy
    if timers is None:
        def timers(delay, fn):
            timer = threading.Timer(delay, fn)
            timer.start()
            return timer
    if settings is None:
        settings = _production_settings
    if queue_ids is None:
        queue_ids = _production_queue_ids
    if timeout is None:
        try:
            from .approval_inbox import DEFAULT_TIMEOUT as timeout
        except ImportError:
            from approval_inbox import DEFAULT_TIMEOUT as timeout
    if status_ok is None:
        status_ok = _production_status_ok

    def metrics():
        return inbox.setdefault("metrics", {})

    def on_result(ok, error_type):
        m = metrics()
        if ok:
            m["send_success"] = m.get("send_success", 0) + 1
        else:
            m["send_fail"] = m.get("send_fail", 0) + 1
            m["send_fail_last"] = str(error_type or "error")  # sanitized; never the topic

    def publish(entry, phase, *, gate=True):
        if gate:
            # R6: while the notification ledger is live it OWNS the dedup of
            # the semantic event (initial and reminder phases); (handled, ok).
            hook = inbox.get("notify_gate")
            if hook is not None:
                handled, ok = hook(phase, {
                    "entry": entry, "pending": entry.get("phase") == "pending",
                    "publish": lambda: publish(entry, phase, gate=False)})
                if handled:
                    return ok
        cfg = settings()
        if not cfg:
            m = metrics()
            m["push_dropped"] = m.get("push_dropped", 0) + 1
            m["push_dropped_config"] = m.get("push_dropped_config", 0) + 1
            log.info("approval push dropped: stage=settings phase=%s run_id=%s request_id=%s",
                     phase, entry["run_id"], entry["request_id"])
            return False
        locale = normalize_locale(cfg.get("locale"))
        title, body = compose(entry, locale=locale, phase=phase, clock=clock)
        click = None
        try:  # R7 deep link: exact run + this request, never key/topic
            try:
                from .notification_events import run_link
            except ImportError:  # flat import context (unit tests)
                from notification_events import run_link
            click = run_link(sid=entry.get("session_id"), run_id=entry.get("run_id"),
                             request_id=entry.get("request_id"))
        except Exception:
            click = None
        accepted = ntfy.publish_json(cfg["server"], cfg["topic"], title, body,
                                     priority="high", tags=["warning"],
                                     on_result=on_result, click=click)
        m = metrics()
        key = "push_enqueued" if accepted else "push_dropped"
        m[key] = m.get(key, 0) + 1
        if not accepted:
            m["push_dropped_queue"] = m.get("push_dropped_queue", 0) + 1
            log.info("approval push dropped: stage=queue phase=%s run_id=%s request_id=%s",
                     phase, entry["run_id"], entry["request_id"])
        return accepted

    def fire(entry):
        try:
            entry["timer"] = None
            if entry["phase"] != "pending" or inbox.get("closed"):
                return
            if entry["request_id"] not in set(queue_ids(entry) or ()):
                return  # core settled quietly: the card is already gone
            if not status_ok(entry):
                return
            remaining = entry["created_mono"] + entry["timeout"] - clock()
            if remaining < 1 or entry["pushed"].get("reminder"):
                return
            entry["pushed"]["reminder"] = bool(publish(entry, "reminder"))
        except Exception:
            pass  # a failed timer never blocks the approval or its timeout

    def dispatch(entry):
        try:
            if inbox.get("closed") or entry["pushed"].get("initial"):
                return
            entry["pushed"]["initial"] = bool(publish(entry, "initial"))
            delay = reminder_delay(timeout())
            if delay is not None:
                entry["timer"] = timers(delay, lambda: fire(entry))
        except Exception as exc:
            # notifications never gate the native approval chain, but the
            # stage and error TYPE stay observable (never topic/credential).
            m = metrics()
            m["dispatch_error"] = m.get("dispatch_error", 0) + 1
            log.info("approval push dispatch failed: stage=dispatch run_id=%s request_id=%s "
                     "error=%s", entry["run_id"], entry["request_id"], type(exc).__name__)

    inbox["dispatch"] = dispatch
    return dispatch


def _production_settings():
    # Profile-aware (server, topic) via the push unit reader + the approval
    # locale; None keeps the legacy exit's "unconfigured -> silence" contract.
    from .compat import _push_settings
    settings = _push_settings()
    if settings is None:
        return None
    server, topic = settings
    from .compat import _push_raw_settings
    raw = _push_raw_settings()
    return {"server": server, "topic": topic, "locale": raw.get("approval_locale")}


def _production_queue_ids(entry):
    from tools import approval
    return [str(item.get("request_id")) for item in
            approval.list_gateway_approvals(entry["session_key"])]


def _production_status_ok(entry):
    adapter = entry.get("adapter")
    if adapter is None:
        return True
    try:
        status = adapter._run_statuses.get(entry["run_id"], {}).get("status")
        return status not in TERMINAL_STATUSES
    except Exception:
        return True
