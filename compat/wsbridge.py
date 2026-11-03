"""TASK-WSBRIDGE: app-facing WebSocket bridge onto the gateway's ticketed /api/ws.

The owner's session WebSocket is loopback-only, refuses any ``Origin`` header
(4403) and is entered with a 30 s single-use ticket that only the owner-only
``gateway.sock`` mints (gateway/run_api.py:322-341, gateway/runtime_bootstrap.py).
A remote app can reach none of that, so this standalone service (its own port,
API_SERVER_KEY bearer auth, never mounted on 8642) holds one upstream
connection per app connection and relays JSON-RPC between them:

* upstream is dialed only through core's ``connect_gateway(endpoint=...)`` with
  an endpoint discovered right before each dial; ``endpoint=None`` would let
  core start a gateway. Every (re)connect rediscovers and remints, nothing is
  cached, and the ticket subject is one fixed principal so ``prompt.submit``
  idempotency keys stay stable across reconnects.
* app -> gateway is allowlisted by method (``ALLOWED_METHODS``); an interactive
  ticket is an operator connection (``shell.exec``, ``config.set`` ...), so
  anything else answers ``method_not_found`` and is logged.
* gateway -> app event frames pass through as sent.
* on an upstream drop (1013 restart/drain included) the link rediscovers,
  remints, replays ``session.resume`` for every session this app connection
  attached and reports each as a ``bridge.resumed`` notification; requests
  wait for that replay, since a submit on a connection that has not resumed
  the session is ``permission_denied`` (gateway/session_controls.py:752).
* writes (submit, steer, interrupt, approval/clarify answers) reach only
  foreign sessions (``sessions.source`` not in ``HTTP_OWNED_SOURCES``) or
  sessions this connection created; any other session may only be resumed. A
  config that lists ``test_thread_ids`` further narrows the foreign sessions to
  those threads; absent means the source alone decides.
* a browser cannot put a header on a WebSocket upgrade, so it first spends the
  key over ``POST /bridge/ticket`` for a random 60 s single-use ticket
  (same shape as core's gateway/session_ticket_store.py) and upgrades with
  ``?ticket=``. Tickets live in memory only; a restart loses them and the client
  mints again.

Run: ``python wsbridge.py [--config PATH]`` with hermes-agent on PYTHONPATH.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import hashlib
import hmac
import json
import logging
import re
import os
import secrets
import sqlite3
import time
from pathlib import Path
from urllib.parse import parse_qs

log = logging.getLogger("hermes_app.wsbridge")

BRIDGE_PATH = "/api/bridge/ws"
TICKET_PATH = "/bridge/ticket"
TICKET_TTL = 60
TICKET_REQUEST = f"POST {TICKET_PATH} ".encode()
TICKET_REQUEST_MAX = 16 * 1024   # same order as websockets' own header limits
# Reverse proxies (Tailscale Serve) forward absolute-form request lines, so the
# sniff accepts either origin-form or any-absolute-form of the ticket path.
TICKET_LINE = re.compile(rb"^(?:POST|GET) (?:\S+)?/bridge/ticket HTTP/1\.[01]\r\n")
_TICKET_PARTIALS = (b"POST ", b"GET ") + tuple(b"POST"[:i] for i in range(1, 4)) + tuple(b"GET"[:i] for i in range(1, 3))
_TICKET_IN_URL = re.compile(rb"([?&]ticket=)[^&\s]+")


def _redact_ticket(line: bytes) -> bytes:
    """Never let a live ticket reach the log through a request-line echo."""
    return _TICKET_IN_URL.sub(rb"\1<redacted>", line)
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8650
CONFIG_ENV = "HERMES_APP_WSBRIDGE_CONFIG"
CONFIG_NAME = "app-wsbridge.json"

ALLOWED_METHODS = frozenset({
    "session.resume", "prompt.submit", "session.steer", "session.interrupt",
    "approval.respond", "clarify.respond", "session.create",
})
# Verbs that change a session: only foreign sessions (or sessions this
# connection created) may receive them.
WRITE_METHODS = frozenset({
    "prompt.submit", "session.steer", "session.interrupt", "approval.respond", "clarify.respond",
})
# These own their sessions on the HTTP API; the bridge never writes to them.
HTTP_OWNED_SOURCES = frozenset({"api_server", "bot_room"})
# gateway/session_busy_controls.py:175-179, session_controls.py:826-830.
GENERATION_METHODS = frozenset({"session.steer", "session.interrupt"})
# ``GatewayClient.rpc`` keyword that never goes on the wire.
RESERVED_PARAMS = frozenset({"_timeout"})

METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INVALID_REQUEST = -32600
PARSE_ERROR = -32700
REFUSED = 4001       # the owner's RuntimeStoreError code (session_controls.py:266)
UPSTREAM = -32000


class UpstreamUnavailable(Exception):
    """No ready owner to dial; the link keeps retrying."""


def subject():
    """The one principal every bridge ticket is minted for (a structured login, the only kind a
    same-user peer may name: gateway/control_socket.py:148-154)."""
    from gateway.session_identity import authenticated_subject
    return authenticated_subject({"provider": "hermes-app", "issuer": "wsbridge", "user_id": "app"})


def discover_endpoint():
    """The live owner's endpoint, or ``UpstreamUnavailable``. Never starts a gateway."""
    from hermes_constants import get_hermes_home
    from hermes_cli.gateway_runtime import attachable, discover_gateway_endpoint, gateway_profile_home
    result = discover_gateway_endpoint(gateway_profile_home(get_hermes_home()))
    if not attachable(result):
        raise UpstreamUnavailable(result.reason_code or result.state)
    return result.endpoint


def state_db_thread_of(db_path):
    """``session_id -> thread_id`` read from ``state.db`` (read-only), None when unknown."""
    return _state_db_column(db_path, "thread_id")


def state_db_source_of(db_path):
    """``session_id -> source`` read from ``state.db`` (read-only), None when unknown."""
    return _state_db_column(db_path, "source")


def _state_db_column(db_path, column):
    def lookup(session_id):
        try:
            con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
        except sqlite3.Error:
            return None
        try:
            row = con.execute(f"SELECT {column} FROM sessions WHERE id = ?", (session_id,)).fetchone()
        except sqlite3.Error:
            return None
        finally:
            con.close()
        return str(row[0]) if row and row[0] else None
    return lookup


def load_config(path):
    """``{host, port, test_thread_ids}``; a missing file means loopback defaults and no thread
    limit. ``test_thread_ids`` is None when absent, an explicit ``[]`` admits no thread at all."""
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except FileNotFoundError:
        raw = {}
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: expected a JSON object")
    threads = raw.get("test_thread_ids")
    if threads is not None and not isinstance(threads, list):
        raise ValueError(f"{path}: test_thread_ids must be a list")
    return {"host": str(raw.get("host") or DEFAULT_HOST), "port": int(raw.get("port") or DEFAULT_PORT),
            "test_thread_ids": None if threads is None else frozenset(str(t) for t in threads)}


def _error(rid, code, message, data=None):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message,
                                                   "data": data or {"reason": message}}}


def ticket_digest(ticket):
    """What the store keeps and, cut to 8 characters, what a log may name."""
    return hashlib.sha256(ticket.encode("utf-8", "surrogateescape")).hexdigest()


class TicketStore:
    """Single-use upgrade tickets, held as digests. Random, so nothing about the key can leak."""

    def __init__(self, ttl=TICKET_TTL, clock=time.monotonic):
        self.ttl = ttl
        self.clock = clock
        self.expiry = {}       # ticket digest -> clock value it stops working at

    def prune(self):
        now = self.clock()
        self.expiry = {digest: at for digest, at in self.expiry.items() if now < at}

    def live(self):
        self.prune()
        return len(self.expiry)

    def mint(self):
        self.prune()
        ticket = secrets.token_urlsafe(32)
        self.expiry[ticket_digest(ticket)] = self.clock() + self.ttl
        return ticket

    def redeem(self, ticket):
        self.prune()
        digest = ticket_digest(ticket)
        found = None
        for known in self.expiry:
            if hmac.compare_digest(known, digest):
                found = known
        return found is not None and self.expiry.pop(found, None) is not None


def _ticket_answer(status, reason, body):
    return (f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body


def _authorization_of(head):
    """The Authorization value of a raw request head; '' when absent or sent twice."""
    values = [line.partition(b":")[2].strip() for line in head.split(b"\r\n")[1:]
              if line.partition(b":")[0].strip().lower() == b"authorization"]
    return values[0].decode("latin-1") if len(values) == 1 else ""


def ticket_connection(bridge):
    """A ``ServerConnection`` that answers ``POST /bridge/ticket`` itself: the websockets parser
    refuses any method but GET (websockets/http11.py ``Request.parse``) before ``process_request``
    could see it, and the Serve mount leaves this one port to share. Everything else reaches
    websockets byte for byte, a refused POST included."""
    from websockets.asyncio.server import ServerConnection

    class TicketConnection(ServerConnection):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.sniffed = b""
            self.sniffing = True
            self.answered = False

        def data_received(self, data):
            if self.answered:
                return
            if not self.sniffing:
                super().data_received(data)
                return
            self.sniffed += data
            head = self.sniffed
            line, sep, _ = head.partition(b"\r\n")
            if b"\r\n" in head:
                settled = TICKET_LINE.match(head) is None
            elif len(head) > TICKET_REQUEST_MAX:
                settled = True
            else:  # request line still arriving: keep sniffing while it could match
                settled = not any(head.startswith(p) for p in _TICKET_PARTIALS)
            if settled:
                log.info("bridge passing a non-ticket request: %s",
                         _redact_ticket(head.split(b"\r\n", 1)[0][:140]))
                self.sniffing, self.sniffed = False, b""
                super().data_received(head)
            elif b"\r\n\r\n" in head:
                self.sniffing, self.sniffed, self.answered = False, b"", True
                self.transport.write(bridge.answer_ticket_request(head, self.transport.get_extra_info("peername")))
                self.transport.close()   # flushes first; open_timeout bounds a head that never ends

        async def handshake(self, *args, **kwargs):
            try:
                await super().handshake(*args, **kwargs)
            except Exception:
                # The answered POST closed the transport with no request parsed: not a failed handshake.
                if not self.answered:
                    raise

    return TicketConnection


class Bridge:
    def __init__(self, *, key, test_thread_ids=None, discover=discover_endpoint, thread_of=None, source_of=None,
                 connect=None, reconnect_delays=(0.5, 1, 2, 5, 10), request_wait=15.0, tickets=None):
        self.key = key
        self.tickets = tickets or TicketStore()
        self.test_thread_ids = None if test_thread_ids is None else frozenset(str(t) for t in test_thread_ids)
        self.discover = discover
        self.thread_of = thread_of or (lambda _sid: None)
        self.source_of = source_of or (lambda _sid: None)
        self.connect = connect
        self.reconnect_delays = tuple(reconnect_delays)
        self.request_wait = request_wait

    def dial(self, endpoint):
        if endpoint is None:
            raise UpstreamUnavailable("no_endpoint")
        connect = self.connect
        if connect is None:
            from hermes_cli.gateway_client import connect_gateway as connect
        return connect(endpoint=endpoint, subject=subject())

    async def may_write(self, session_id):
        # An unknown source is no evidence of a foreign session: refuse.
        source = await asyncio.to_thread(self.source_of, session_id)
        if not source or source in HTTP_OWNED_SOURCES:
            return False
        if self.test_thread_ids is None:
            return True
        thread = await asyncio.to_thread(self.thread_of, session_id)
        return thread is not None and str(thread) in self.test_thread_ids

    def bearer_ok(self, authorization):
        scheme, _, token = authorization.partition(" ")
        return bool(scheme.lower() == "bearer" and self.key
                    and hmac.compare_digest(token.strip().encode(), self.key.encode()))

    def authorize(self, connection, request):
        path, _, query = request.path.partition("?")
        if path != BRIDGE_PATH:
            return connection.respond(404, "not found\n")
        if self.bearer_ok(request.headers.get("Authorization", "")):
            return None
        tickets = parse_qs(query).get("ticket", [])
        if len(tickets) == 1 and self.tickets.redeem(tickets[0]):
            return None
        if tickets:
            log.warning("bridge refused ticket %s from %s",
                        ",".join(ticket_digest(t)[:8] for t in tickets), connection.remote_address)
        else:
            log.warning("bridge refused an unauthenticated upgrade from %s", connection.remote_address)
        return connection.respond(401, "unauthorized\n")

    def answer_ticket_request(self, head, peer):
        if not self.bearer_ok(_authorization_of(head)):
            log.warning("bridge refused a ticket request from %s", peer)
            return _ticket_answer(401, "Unauthorized", b'{"error":"unauthorized"}')
        body = {"ticket": self.tickets.mint(), "expires_in": self.tickets.ttl}
        return _ticket_answer(200, "OK", json.dumps(body).encode())

    async def serve(self, host, port):
        from websockets.asyncio.server import serve
        return await serve(lambda ws: AppLink(self, ws).run(), host, port,
                           process_request=self.authorize, max_size=8 * 1024 * 1024,
                           create_connection=ticket_connection(self))


class AppLink:
    """One app connection and the single upstream connection it owns (subscriptions are per
    connection, so app connections never share an upstream)."""

    def __init__(self, bridge, ws):
        self.bridge = bridge
        self.ws = ws
        self.client = None
        self.ready = asyncio.Event()
        self.aliases = {}      # session id the app named -> id the resume answered with
        self.attached = []     # resumed ids, replayed in order after a reconnect
        self.created = set()
        self.send_lock = asyncio.Lock()
        self.background = set()

    async def send(self, frame):
        from websockets.exceptions import ConnectionClosed
        async with self.send_lock:
            with contextlib.suppress(ConnectionClosed):
                await self.ws.send(json.dumps(frame))

    async def run(self):
        from websockets.exceptions import ConnectionClosed
        upstream = asyncio.create_task(self.upstream())
        try:
            async for raw in self.ws:
                await self.request(raw)
        except ConnectionClosed:
            pass
        finally:
            for task in (upstream, *self.background):
                task.cancel()
            await asyncio.gather(upstream, *self.background, return_exceptions=True)

    # -- upstream state machine: discover -> mint+dial -> replay resumes -> ready -> pump --
    async def upstream(self):
        from hermes_cli.gateway_client import GatewayClientError
        attempt, was_ready = 0, False
        while True:
            try:
                endpoint = await asyncio.to_thread(self.bridge.discover)
                async with self.bridge.dial(endpoint) as client:
                    await self.replay(client)
                    self.client, attempt = client, 0
                    self.ready.set()
                    if was_ready:
                        await self.send({"jsonrpc": "2.0", "method": "bridge.upstream", "params": {"state": "ready"}})
                    was_ready = True
                    await self.pump(client)
                log.info("bridge upstream closed; reconnecting")
            except (UpstreamUnavailable, GatewayClientError, OSError) as exc:
                log.warning("bridge upstream unavailable: %s", exc)
            finally:
                self.ready.clear()
                self.client = None
            if was_ready and attempt == 0:
                await self.send({"jsonrpc": "2.0", "method": "bridge.upstream", "params": {"state": "reconnecting"}})
            delays = self.bridge.reconnect_delays
            await asyncio.sleep(delays[min(attempt, len(delays) - 1)])
            attempt += 1

    async def replay(self, client):
        for session_id in list(self.attached):
            await self.resume_again(client, session_id)

    async def resume_again(self, client, session_id):
        from hermes_cli.gateway_client import GatewayRPCError
        try:
            result = await client.rpc("session.resume", session_id=session_id)
        except GatewayRPCError as exc:
            # Deleted or superseded meanwhile: stop replaying it and say so.
            self.attached.remove(session_id)
            await self.send({"jsonrpc": "2.0", "method": "bridge.resume_failed", "params": {
                "session_id": session_id, "error": {"code": exc.code, "message": str(exc), "data": exc.data}}})
            return
        await self.send({"jsonrpc": "2.0", "method": "bridge.resumed",
                         "params": {"session_id": session_id, "result": result}})

    async def pump(self, client):
        while True:
            frame = await client.events.get()
            if isinstance(frame, Exception):   # the reader's disconnect marker
                return
            await self.send(frame)
            params = frame.get("params") if isinstance(frame.get("params"), dict) else {}
            if params.get("type") == "session.replay_gap" and params.get("session_id") in self.attached:
                # The owner revoked this subscription (session_events.py:56-63): resume afresh.
                task = asyncio.create_task(self.resume_again(client, params["session_id"]))
                self.background.add(task)
                task.add_done_callback(self.background.discard)

    async def upstream_client(self):
        try:
            await asyncio.wait_for(self.ready.wait(), self.bridge.request_wait)
        except asyncio.TimeoutError:
            return None
        return self.client

    # -- app -> gateway --
    async def request(self, raw):
        try:
            frame = json.loads(raw)
        except ValueError:
            await self.send(_error(None, PARSE_ERROR, "parse_error"))
            return
        if not isinstance(frame, dict):
            await self.send(_error(None, INVALID_REQUEST, "invalid_request"))
            return
        rid, method = frame.get("id"), frame.get("method")
        if method not in ALLOWED_METHODS:
            log.warning("bridge refused method %r", method if isinstance(method, str) else type(method).__name__)
            if rid is not None:
                await self.send(_error(rid, METHOD_NOT_FOUND, "method_not_found"))
            return
        if rid is None:
            log.warning("bridge dropped %s sent without an id", method)
            return
        reply = await self.call(rid, method, frame.get("params", {}))
        await self.send(reply)

    async def call(self, rid, method, params):
        from hermes_cli.gateway_client import GatewayClientError, GatewayRPCError
        if not isinstance(params, dict) or set(params) & RESERVED_PARAMS:
            return _error(rid, INVALID_PARAMS, "invalid_params")
        if method in GENERATION_METHODS and (type(params.get("execution_generation")) is not int):
            return _error(rid, INVALID_PARAMS, "invalid_params", {"reason": "invalid_params",
                                                                  "field": "execution_generation"})
        if method != "session.create":
            session_id = params.get("session_id")
            if not isinstance(session_id, str) or not session_id:
                return _error(rid, INVALID_PARAMS, "invalid_params", {"reason": "invalid_params",
                                                                      "field": "session_id"})
            if method != "session.resume":
                target = self.aliases.get(session_id)
                if target is None:
                    # Same refusal the owner gives a submit on a connection that never resumed.
                    return _error(rid, REFUSED, "permission_denied", {"reason": "permission_denied",
                                                                      "detail": "resume_required"})
                params = {**params, "session_id": target}
                if method in WRITE_METHODS and target not in self.created and not await self.bridge.may_write(target):
                    log.warning("bridge refused %s on non-allowlisted session %s", method, target)
                    return _error(rid, REFUSED, "session_not_allowlisted")
        client = await self.upstream_client()
        if client is None:
            return _error(rid, UPSTREAM, "upstream_unavailable")
        try:
            result = await client.rpc(method, **params)
        except GatewayRPCError as exc:
            return _error(rid, exc.code if exc.code is not None else UPSTREAM, str(exc), exc.data)
        except GatewayClientError:
            # The answer was lost with the connection: a submit retried with the same
            # submission_id is idempotent, anything else should re-read after resume.
            return _error(rid, UPSTREAM, "upstream_disconnected", {"reason": "upstream_disconnected",
                                                                   "outcome": "unknown"})
        except asyncio.TimeoutError:
            return _error(rid, UPSTREAM, "upstream_timeout", {"reason": "upstream_timeout", "outcome": "unknown"})
        if method in ("session.resume", "session.create") and isinstance(result, dict):
            resumed = result.get("session_id") or params.get("session_id")
            if isinstance(resumed, str) and resumed:
                if method == "session.resume":
                    self.aliases[params["session_id"]] = resumed
                else:
                    self.created.add(resumed)
                self.aliases[resumed] = resumed
                if resumed not in self.attached:
                    self.attached.append(resumed)
        return {"jsonrpc": "2.0", "id": rid, "result": result}


def _api_server_key(home):
    key = os.environ.get("API_SERVER_KEY", "").strip()
    if key:
        return key
    try:
        from dotenv import dotenv_values
        return (dotenv_values(Path(home) / ".env").get("API_SERVER_KEY") or "").strip()
    except Exception:
        return ""


async def _serve_forever(bridge, host, port):
    server = await bridge.serve(host, port)
    limit = "source only" if bridge.test_thread_ids is None else f"{len(bridge.test_thread_ids)} test thread(s)"
    log.info("wsbridge listening on %s:%s%s (%s)", host, port, BRIDGE_PATH, limit)
    async with server:
        await server.serve_forever()


def main(argv=None):
    from hermes_constants import get_hermes_home
    home = Path(get_hermes_home())
    parser = argparse.ArgumentParser(description="hermes-app WebSocket bridge onto the gateway /api/ws")
    parser.add_argument("--config", default=os.environ.get(CONFIG_ENV) or str(home / CONFIG_NAME))
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = load_config(args.config)
    key = _api_server_key(home)
    if not key:
        raise SystemExit("wsbridge: API_SERVER_KEY is unavailable; refusing to serve unauthenticated")
    bridge = Bridge(key=key, test_thread_ids=cfg["test_thread_ids"],
                    thread_of=state_db_thread_of(home / "state.db"),
                    source_of=state_db_source_of(home / "state.db"))
    asyncio.run(_serve_forever(bridge, args.host or cfg["host"], args.port or cfg["port"]))


if __name__ == "__main__":
    main()
