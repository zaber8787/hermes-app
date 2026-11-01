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
"""
from __future__ import annotations

import contextvars
from functools import wraps
import inspect

EXCLUDED = ("cron",)
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


def install(cls, db_cls, tx):
    check(cls, db_cls)
    old_list = cls._handle_list_sessions
    old_rich = db_cls.list_sessions_rich

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

    tx.set(cls, "_handle_list_sessions", list_sessions)
    tx.set(db_cls, "list_sessions_rich", list_sessions_rich)
