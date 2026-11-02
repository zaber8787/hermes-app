"""TASK-PROGRESSBRIDGE: cron run records leave the app's conversation list.

Every scheduled run is a ``source='cron'`` session row. ``GET /api/sessions``
lists them beside real conversations (the app showed hundreds of untitled,
zero-message "cron" rows), and since core caps a page at 200 rows they also
push real conversations off the one page the app reads.

This unit wraps the list handler only: while it runs and the request names no
``source``, ``SessionDB.list_sessions_rich`` gets core's own
``exclude_sources=['cron']``, so the filter is in SQL, before LIMIT/OFFSET.
``?source=cron`` still lists them and ``GET /api/sessions/{id}`` (or its
messages) still reads any one of them; nothing else calls the list with the
flag set. No core file is written.

TASK-WSAUTO: core's ``_session_response`` keeps a fixed key list, which drops
``thread_id`` and says nothing about who owns the session. The wrapper adds
``foreign_source: true`` for a session the HTTP API does not own (the app routes
those over the WS bridge) and its ``thread_id`` when it has one. Every response
built from it carries them, not just the list.
"""
from __future__ import annotations

import contextvars
from functools import wraps
import inspect

EXCLUDED = ("cron",)
# Sources that own their sessions on the HTTP API; compat/wsbridge.py refuses the same set.
HTTP_OWNED = frozenset({"api_server", "bot_room"})
# Set only inside the wrapped GET /api/sessions; asyncio.to_thread copies it to the worker.
_LISTING = contextvars.ContextVar("hermes_app_session_list", default=False)


def check(cls, db_cls):
    """Load-time drift check; raises (the unit is then skipped, loudly) when a seam moved."""
    handler = getattr(cls, "_handle_list_sessions", None)
    lister = getattr(db_cls, "list_sessions_rich", None)
    if not callable(handler) or not callable(lister):
        raise RuntimeError("missing _handle_list_sessions or list_sessions_rich")
    params = inspect.signature(lister).parameters
    if not {"source", "sources", "exclude_sources"} <= params.keys():
        raise RuntimeError("signature changed: list_sessions_rich")
    text = inspect.getsource(inspect.unwrap(handler))
    for needle in ('request.query.get("source")', "db.list_sessions_rich"):
        if needle not in text:
            raise RuntimeError(f"source changed: _handle_list_sessions ({needle})")
    if "self._session_response(" not in text:
        raise RuntimeError("source changed: _handle_list_sessions (self._session_response)")
    if not isinstance(inspect.getattr_static(cls, "_session_response", None), staticmethod):
        raise RuntimeError("missing static _session_response")
    if "def _session_response(session" not in inspect.getsource(cls._session_response):
        raise RuntimeError("source changed: _session_response")


def install(cls, db_cls, tx):
    check(cls, db_cls)
    old_list = cls._handle_list_sessions
    old_rich = db_cls.list_sessions_rich
    old_response = cls._session_response

    @wraps(old_list)
    async def list_sessions(self, request, *args, **kwargs):
        token = _LISTING.set(True)
        try:
            return await old_list(self, request, *args, **kwargs)
        finally:
            _LISTING.reset(token)

    @wraps(old_rich)
    def list_sessions_rich(self, *args, **kwargs):
        if _LISTING.get() and not args and kwargs.get("source") is None and not kwargs.get("sources"):
            kwargs["exclude_sources"] = sorted(set(kwargs.get("exclude_sources") or ()) | set(EXCLUDED))
        return old_rich(self, *args, **kwargs)

    @wraps(old_response)
    def session_response(session):
        payload = old_response(session)
        source = session.get("source")
        if source and source not in HTTP_OWNED:
            payload["foreign_source"] = True
            if session.get("thread_id"):
                payload["thread_id"] = str(session["thread_id"])
        return payload

    tx.set(cls, "_handle_list_sessions", list_sessions)
    tx.set(cls, "_session_response", staticmethod(session_response))
    tx.set(db_cls, "list_sessions_rich", list_sessions_rich)
