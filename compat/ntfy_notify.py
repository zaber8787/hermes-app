"""Fire-and-forget ntfy publish for the hermes-app-compat push unit.

Wakes the phone when the app can't: an approval card nobody tapped, a run that
finished with no live SSE viewer, a failed run. Config lives in the profile's
config.yaml (read by compat.py, never here):

    push:
      ntfy_server: http://127.0.0.1:8090
      ntfy_topic: hermes-zz-xxxx        # the topic name IS the secret

Never raises, never blocks the caller: one bounded queue fed by at most one
worker thread per process, a five-second timeout and no retry (each event is
one enqueue / one POST attempt at best; a closing daemon or a dead hub loses
it). Titles stay ASCII (HTTP header charset); the Chinese goes in the UTF-8
body, byte-bounded without cutting a code point. Failures log a bare exception
type only -- the topic is a secret and never reaches the log.
"""
from __future__ import annotations

import json
import logging
import queue
from contextlib import suppress
import threading
import urllib.parse
import urllib.request

log = logging.getLogger("hermes-app-compat.push")

PRIORITY = {"default": "3", "high": "4", "urgent": "5"}
TITLE_CAP = 120
TITLE_BYTES = 120           # UTF-8 bytes for JSON-body titles (Unicode aware)
BODY_BYTES = 1900          # UTF-8 bytes, well under ntfy's 4096 message limit
TIMEOUT_SECONDS = 5
_QUEUE_CAP = 128            # bounded backlog; a full queue drops, never grows
_ECHO_TAG = "hermes-agent"  # matches the ntfy platform adapter's skip tag

_jobs: "queue.Queue" = queue.Queue(maxsize=_QUEUE_CAP)
_lock = threading.Lock()
_worker: threading.Thread | None = None


def utf8_cut(text: str, cap: int) -> str:
    """Truncate to at most `cap` UTF-8 bytes without splitting a code point."""
    raw = text.encode("utf-8")
    if len(raw) <= cap:
        return text
    cut = raw[:cap]
    while True:
        try:
            return cut.decode("utf-8")
        except UnicodeDecodeError:
            cut = cut[:-1]


def _send(job: tuple) -> None:
    if job[0] == "json":
        _send_json(job[1])
        return
    server, topic, title, message, priority, tags = job
    try:
        url = server + "/" + urllib.parse.quote(topic, safe="")
        request = urllib.request.Request(url, data=message.encode("utf-8"), method="POST")
        request.add_header("Title", title)
        request.add_header("Priority", PRIORITY.get(priority, PRIORITY["default"]))
        if tags:
            request.add_header("Tags", ",".join(tags))
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            response.read()
    except Exception as exc:  # push must never break the agent loop
        log.debug("ntfy publish failed: %s", type(exc).__name__)


def _send_json(fields: tuple) -> None:
    """JSON-body publish: the ONLY way a Unicode title reaches the hub
    (HTTP header values stay ASCII). Body bytes keep the hard cap; the title
    is byte-capped like before. One attempt, no retry, never raises. The
    optional click URL (STEERWEB R7) opens the app at the exact run/event;
    it carries NO key, topic or other secret."""
    server, topic, title, message, priority, tags, on_result = fields[:7]
    click = fields[7] if len(fields) > 7 else None
    try:
        body = {"topic": topic, "title": title, "message": message,
                # JSON API wants an INTEGER priority; the header transport's
                # string form is rejected 400 by the hub (misleading
                # "body must be valid JSON" error). One bug hid every
                # ledger publish for a full release cycle.
                "priority": int(PRIORITY.get(priority, PRIORITY["default"])),
                "tags": tags or []}
        if click:
            body["click"] = str(click)[:1024]
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(server, data=payload, method="POST")
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            response.read()
    except Exception as exc:
        log.debug("ntfy json publish failed: %s", type(exc).__name__)
        if on_result is not None:
            with suppress(Exception):
                on_result(False, type(exc).__name__)
        return
    if on_result is not None:
        with suppress(Exception):
            on_result(True, None)


def _loop() -> None:
    while True:
        _send(_jobs.get())


def _ensure_worker() -> None:
    global _worker
    with _lock:
        if _worker is None or not _worker.is_alive():
            worker = threading.Thread(target=_loop, daemon=True, name="hermes-app-push")
            worker.start()
            _worker = worker


def publish(server: str, topic: str, title: str, message: str, *,
            priority: str = "default", tags: list[str] | None = None) -> None:
    """Enqueue one notification; silently no-op when unconfigured, saturated
    or on any error. The echo tag is always present so the ntfy platform
    adapter never treats this event as a new prompt."""
    if not server or not topic:
        return
    title = title.encode("ascii", "ignore").decode("ascii")[:TITLE_CAP]
    message = utf8_cut(message, BODY_BYTES)
    safe_tags = ["hermes-agent"] + [
        tag for tag in (tags or []) if tag and tag != "hermes-agent"]
    try:
        _ensure_worker()
        _jobs.put_nowait((server, topic, title, message, priority, safe_tags))
    except queue.Full:
        log.debug("ntfy publish dropped (bounded queue full)")
    except Exception as exc:
        log.debug("ntfy publish enqueue failed: %s", type(exc).__name__)


def publish_json(server: str, topic: str, title: str, message: str, *,
                 priority: str = "default", tags: list[str] | None = None,
                 on_result=None, click: str | None = None) -> bool:
    """Enqueue one JSON-body notification (Unicode title allowed). Returns
    whether the LOCAL queue accepted it — accepted is not delivery; the
    optional on_result(ok, sanitized_error_type) records the single POST
    attempt's outcome. Never raises, never blocks, echoes the same tag."""
    if not server or not topic:
        return False
    title = utf8_cut(title, TITLE_BYTES)
    message = utf8_cut(message, BODY_BYTES)
    safe_tags = ["hermes-agent"] + [
        tag for tag in (tags or []) if tag and tag != "hermes-agent"]
    try:
        _ensure_worker()
        _jobs.put_nowait(("json", (server, topic, title, message, priority,
                                   safe_tags, on_result, click)))
        return True
    except queue.Full:
        log.debug("ntfy publish dropped (bounded queue full)")
        return False
    except Exception as exc:
        log.debug("ntfy publish enqueue failed: %s", type(exc).__name__)
        return False
