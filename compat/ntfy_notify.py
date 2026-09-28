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

import logging
import queue
import threading
import urllib.parse
import urllib.request

log = logging.getLogger("hermes-app-compat.push")

PRIORITY = {"default": "3", "high": "4", "urgent": "5"}
TITLE_CAP = 120
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
