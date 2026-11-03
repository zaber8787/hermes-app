"""TASK-WSBRIDGE: the app-facing WebSocket bridge onto the gateway's /api/ws.

The bridge dials upstream through core's own ``connect_gateway(endpoint=...)``
(real subprotocol negotiation, real ``GatewayClient``); only the two pieces that
need a live owner are faked: ``discover`` (an endpoint pointing at a fake
gateway on loopback) and ``hermes_cli.gateway_client._session_ticket`` (a
ticket store with core's rules: 30 s TTL, single use, bound to the instance).
The fake gateway answers like ``gateway/session_controls.py``: submit before
resume on the same connection is ``4001 permission_denied``, an unknown verb is
``-32601``, a messaging continuation resumes to its lineage root.
"""
import asyncio
import contextlib
import json
import os
import secrets
import sqlite3
import tempfile
import unittest
from unittest import mock

from websockets.asyncio.client import connect as ws_connect
from websockets.asyncio.server import serve as ws_serve
from websockets.exceptions import InvalidStatus

from hermes_cli import gateway_client
from hermes_cli.gateway_runtime import GatewayEndpoint

from compat import wsbridge

BEARER = secrets.token_urlsafe(16)   # per-run bearer for the bridge under test
TEST_THREAD = "1600000000000000001"
PROD_THREAD = "1600000000000000009"
ALIAS = "20261101_000000_cont0001"   # a compression continuation
ROOT = "20261101_000000_root0001"    # ... whose lineage root the resume names
PROD = "20261101_000000_prod0001"
THREADS = {ALIAS: TEST_THREAD, ROOT: TEST_THREAD, PROD: PROD_THREAD}
CRON = "20261101_000000_cron0001"    # foreign, no Discord thread
API = "20261101_000000_api00001"
ROOM = "20261101_000000_room0001"
SOURCES = {ALIAS: "discord", ROOT: "discord", PROD: "discord", CRON: "cron", API: "api_server", ROOM: "bot_room"}
# gateway/session_cron.py:113 and the settled completion it renders (session_settlement_recovery.py:66-73).
CRON_REFUSAL = {"role": "assistant", "status": "error", "text": "This chat belongs to a scheduled job",
                "error_surface": {"layer": "gateway", "code": "cron_session_read_only", "retryable": False}}


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class FakeGateway:
    """Loopback stand-in for the runtime listener's ticketed ``/api/ws``."""

    def __init__(self, clock):
        self.clock = clock
        self.instance = "inst-1"
        self.tickets = {}          # ticket -> (minted_at, subject, instance)
        self.minted = []
        self.handshakes = []       # (origin header, offered subprotocols)
        self.seen = []             # (connection number, method, params)
        self.refused = []          # close reasons for rejected upgrades
        self.messages = {}         # session_id -> rows, the fake ``messages`` table
        self.generation = 7
        self.conns = []
        self.server = None
        self.port = None

    # -- ticket store with core's rules (gateway/runtime_bootstrap.py) --
    def mint(self, home, endpoint, *, purpose="interactive", scope=None, subject=None):
        assert endpoint is not None
        if endpoint.instance_id != self.instance:
            raise gateway_client.GatewayClientError("stale runtime instance")
        ticket = f"tk{len(self.minted) + 1}"
        self.tickets[ticket] = (self.clock(), subject, endpoint.instance_id)
        self.minted.append((ticket, subject, purpose))
        return ticket

    def redeem(self, ticket):
        grant = self.tickets.pop(ticket, None)   # single use
        if grant is None:
            return False
        minted_at, _subject, instance = grant
        return self.clock() - minted_at <= 30 and instance == self.instance

    def endpoint(self):
        return GatewayEndpoint(profile_id="p", instance_id=self.instance, authority_epoch=1, runtime_protocol=1,
                               api_origin=f"http://127.0.0.1:{self.port}", supervisor="launchd",
                               capabilities=frozenset({"session-authority-v1"}))

    async def start(self):
        def select(connection, offered):
            return "hermes-gateway-v1" if "hermes-gateway-v1" in offered else None
        self.server = await ws_serve(self.handler, "127.0.0.1", 0, select_subprotocol=select)
        self.port = self.server.sockets[0].getsockname()[1]

    async def stop(self):
        self.server.close()
        await self.server.wait_closed()

    async def drop(self, code=1013):
        for conn in list(self.conns):
            await conn.close(code)

    async def handler(self, ws):
        offered = [p.strip() for p in ws.request.headers.get("Sec-WebSocket-Protocol", "").split(",") if p.strip()]
        self.handshakes.append((ws.request.headers.get("Origin"), offered))
        tickets = [p[len("hermes-gateway-ticket."):] for p in offered if p.startswith("hermes-gateway-ticket.")]
        if ws.request.headers.get("Origin") or len(tickets) != 1 or not self.redeem(tickets[0]):
            self.refused.append("origin" if ws.request.headers.get("Origin") else "ticket")
            await ws.close(4403)
            return
        number = len(self.conns) + 1
        self.conns.append(ws)
        subscriptions = set()
        seq = 0
        try:
            async for raw in ws:
                frame = json.loads(raw)
                method, params, rid = frame.get("method"), frame.get("params") or {}, frame.get("id")
                self.seen.append((number, method, params))

                def ok(result):
                    return {"jsonrpc": "2.0", "id": rid, "result": result}

                def err(code, message):
                    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message,
                                                                   "data": {"reason": message}}}
                sid = params.get("session_id")
                if method == "session.resume":
                    root = ROOT if sid == ALIAS else sid
                    subscriptions.add(root)
                    reply = ok({"session_id": root, "stored_session_id": root,
                                "messages": list(self.messages.get(root, [])), "running": False,
                                "execution_generation": self.generation, "replay_epoch": "e1",
                                "last_sequence": seq, "prompts": [], "pending": []})
                elif method == "session.create":
                    sid = f"local-new{number}"
                    subscriptions.add(sid)
                    reply = ok({"session_id": sid, "execution_generation": 0})
                elif method == "prompt.submit":
                    if sid not in subscriptions:
                        reply = err(4001, "permission_denied")
                    else:
                        self.messages.setdefault(sid, []).append({"role": "user", "content": params.get("text")})
                        reply = ok({"admission_id": "adm1", "status": "queued", "outcome": "admitted",
                                    "execution_generation": self.generation})
                        await ws.send(json.dumps(reply))
                        turn = (("message.complete", CRON_REFUSAL),) if sid == CRON else (
                            ("message.delta", {"text": "po"}),
                            ("message.complete", {"text": "pong", "role": "assistant"}))
                        for kind, payload in turn:
                            seq += 1
                            await ws.send(json.dumps({"jsonrpc": "2.0", "method": "event", "params": {
                                "type": kind, "session_id": sid, "payload": payload, "replay_epoch": "e1",
                                "seq": seq, "execution_generation": self.generation}}))
                        self.messages[sid].append({"role": "assistant", "content": "pong"})
                        continue
                elif method in ("session.steer", "session.interrupt"):
                    if sid not in subscriptions:
                        reply = err(4001, "permission_denied")
                    elif not isinstance(params.get("execution_generation"), int):
                        reply = err(4001, "invalid_params")
                    else:
                        reply = ok({"status": "queued", "delivered": True})
                else:
                    reply = err(-32601, "unknown method")
                await ws.send(json.dumps(reply))
        except Exception:
            pass


class BridgeHarness:
    def __init__(self, test_thread_ids=(TEST_THREAD,)):
        self.clock = Clock()
        self.gateway = FakeGateway(self.clock)
        self.discovered = 0
        self.test_thread_ids = test_thread_ids
        self.discover_ok = True

    def discover(self):
        self.discovered += 1
        if not self.discover_ok:
            raise wsbridge.UpstreamUnavailable("stopped")
        return self.gateway.endpoint()

    async def __aenter__(self):
        self._home = tempfile.TemporaryDirectory()
        self._patches = [mock.patch.object(gateway_client, "_session_ticket", self.gateway.mint),
                         mock.patch.dict(os.environ, {"HERMES_HOME": self._home.name})]
        for p in self._patches:
            p.start()
        await self.gateway.start()
        self.bridge = wsbridge.Bridge(key=BEARER, test_thread_ids=self.test_thread_ids, discover=self.discover,
                                      thread_of=THREADS.get, source_of=SOURCES.get, reconnect_delays=(0.05,), request_wait=2.0)
        self.server = await self.bridge.serve("127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *exc):
        self.server.close()
        await self.server.wait_closed()
        await self.gateway.stop()
        for p in reversed(self._patches):
            p.stop()
        self._home.cleanup()

    @contextlib.asynccontextmanager
    async def app(self, headers=None):
        hdrs = {"Authorization": f"Bearer {BEARER}", **(headers or {})}
        async with ws_connect(f"ws://127.0.0.1:{self.port}{wsbridge.BRIDGE_PATH}", additional_headers=hdrs,
                              proxy=None) as ws:
            yield AppClient(ws)


class AppClient:
    def __init__(self, ws):
        self.ws = ws
        self.n = 0
        self.events = []

    async def call(self, method, **params):
        self.n += 1
        rid = self.n
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        return await self.reply(rid)

    async def reply(self, rid):
        while True:
            frame = json.loads(await asyncio.wait_for(self.ws.recv(), 5))
            if frame.get("id") == rid and "method" not in frame:
                return frame
            self.events.append(frame)

    async def until_event(self, predicate):
        for frame in self.events:
            if predicate(frame):
                return frame
        while True:
            frame = json.loads(await asyncio.wait_for(self.ws.recv(), 5))
            self.events.append(frame)
            if predicate(frame):
                return frame


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, 20))


class ResumeSubmit(unittest.TestCase):
    def test_resume_then_submit_lands_user_row_and_streams_assistant(self):
        async def main():
            async with BridgeHarness() as h, h.app() as app:
                resumed = await app.call("session.resume", session_id=ALIAS)
                # lineage: the resume names the root; the bridge maps the alias onto it
                self.assertEqual(resumed["result"]["session_id"], ROOT)
                receipt = await app.call("prompt.submit", session_id=ALIAS, submission_id="s1", text="ping")
                self.assertEqual(receipt["result"]["outcome"], "admitted")
                done = await app.until_event(lambda f: f.get("method") == "event"
                                             and f["params"]["type"] == "message.complete")
                self.assertEqual(done["params"]["payload"]["text"], "pong")
                self.assertEqual(done["params"]["session_id"], ROOT)
                self.assertIn({"role": "user", "content": "ping"}, h.gateway.messages[ROOT])
                submits = [p for _, m, p in h.gateway.seen if m == "prompt.submit"]
                self.assertEqual(submits, [{"session_id": ROOT, "submission_id": "s1", "text": "ping"}])
        run(main())

    def test_submit_before_resume_is_permission_denied(self):
        async def main():
            async with BridgeHarness() as h, h.app() as app:
                reply = await app.call("prompt.submit", session_id=ROOT, submission_id="s1", text="ping")
                self.assertEqual(reply["error"]["code"], 4001)
                self.assertEqual(reply["error"]["message"], "permission_denied")
                self.assertEqual(h.gateway.messages, {})
        run(main())

    def test_steer_and_interrupt_require_execution_generation(self):
        async def main():
            async with BridgeHarness() as h, h.app() as app:
                gen = (await app.call("session.resume", session_id=ROOT))["result"]["execution_generation"]
                for method, extra in (("session.steer", {"text": "also"}), ("session.interrupt", {})):
                    bad = await app.call(method, session_id=ROOT, **extra)
                    self.assertEqual(bad["error"]["code"], -32602)
                    good = await app.call(method, session_id=ROOT, execution_generation=gen, **extra)
                    self.assertIn("result", good)
                forwarded = [m for _, m, p in h.gateway.seen if m in ("session.steer", "session.interrupt")]
                self.assertEqual(forwarded, ["session.steer", "session.interrupt"])
        run(main())


class MethodAllowlist(unittest.TestCase):
    def test_operator_verbs_and_response_frames_are_method_not_found(self):
        async def main():
            async with BridgeHarness() as h, h.app() as app:
                await app.call("session.resume", session_id=ROOT)
                with self.assertLogs(wsbridge.log, "WARNING") as logs:
                    for method in ("shell.exec", "rollback.restore", "session.delete", "config.set",
                                   "reload.env", "session.events.since", "session.mutate"):
                        reply = await app.call(method, session_id=ROOT)
                        self.assertEqual(reply["error"]["code"], -32601, method)
                        self.assertEqual(reply["error"]["message"], "method_not_found")
                    # a JSON-RPC response frame (answering a server request) is not a method call
                    await app.ws.send(json.dumps({"jsonrpc": "2.0", "id": 99, "result": {"ok": True}}))
                    reply = await app.reply(99)
                    self.assertEqual(reply["error"]["code"], -32601)
                self.assertTrue(any("shell.exec" in line for line in logs.output))
                leaked = {m for _, m, _ in h.gateway.seen} - wsbridge.ALLOWED_METHODS
                self.assertEqual(leaked, set())
        run(main())

    def test_allowlist_is_exactly_the_task_set(self):
        self.assertEqual(wsbridge.ALLOWED_METHODS, frozenset({
            "session.resume", "prompt.submit", "session.steer", "session.interrupt",
            "approval.respond", "clarify.respond", "session.create"}))


class UpstreamHandshake(unittest.TestCase):
    def test_origin_is_dropped_and_exactly_one_ticket_protocol_offered(self):
        async def main():
            async with BridgeHarness() as h, h.app({"Origin": "https://app.example"}) as app:
                reply = await app.call("session.resume", session_id=ROOT)
                self.assertIn("result", reply)
                origin, offered = h.gateway.handshakes[0]
                self.assertIsNone(origin)
                self.assertEqual(offered[0], "hermes-gateway-v1")
                self.assertEqual(len([p for p in offered if p.startswith("hermes-gateway-ticket.")]), 1)
                self.assertEqual(h.gateway.refused, [])
                # the ticket is minted for the bridge's one fixed subject
                self.assertEqual({s for _, s, _ in h.gateway.minted}, {wsbridge.subject()})
        run(main())

    def test_subject_is_a_structured_login_core_accepts(self):
        from gateway.control_socket import _structured_login_subject
        self.assertTrue(_structured_login_subject(wsbridge.subject()))

    def test_bad_or_missing_key_is_refused_at_upgrade(self):
        async def main():
            async with BridgeHarness() as h:
                for headers in ({}, {"Authorization": "Bearer wrong"}):
                    with self.assertRaises(InvalidStatus) as ctx:
                        async with ws_connect(f"ws://127.0.0.1:{h.port}{wsbridge.BRIDGE_PATH}",
                                              additional_headers=headers, proxy=None):
                            pass
                    self.assertEqual(ctx.exception.response.status_code, 401)
                self.assertEqual(h.gateway.minted, [])   # nothing dialed upstream
        run(main())


class BridgeTicket(unittest.TestCase):
    """``GET /bridge/ticket`` and ``?ticket=``: the browser's way in, one upgrade per ticket."""

    @staticmethod
    async def post(port, *, key=BEARER, chunks=None):
        """A raw POST: answers (status, headers text, json body)."""
        auth = f"Authorization: Bearer {key}\r\n" if key else ""
        raw = (f"GET {wsbridge.TICKET_PATH} HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: 0\r\n\r\n").encode()
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        for piece in (chunks(raw) if chunks else [raw]):
            writer.write(piece)
            await writer.drain()
            await asyncio.sleep(0.01)
        answer = await asyncio.wait_for(reader.read(), 5)   # EOF: the bridge closes after answering
        writer.close()
        head, _, body = answer.partition(b"\r\n\r\n")
        return int(head.split()[1]), head.decode().lower(), json.loads(body) if body.startswith(b"{") else body

    @staticmethod
    def dial(port, ticket, headers=None):
        return ws_connect(f"ws://127.0.0.1:{port}{wsbridge.BRIDGE_PATH}?ticket={ticket}",
                          additional_headers=headers or {}, proxy=None)

    def assert_refused(self, port, ticket):
        async def attempt():
            with self.assertRaises(InvalidStatus) as ctx:
                async with self.dial(port, ticket):
                    pass
            self.assertEqual(ctx.exception.response.status_code, 401)
        return attempt()

    def test_minted_ticket_opens_a_working_link_without_a_header(self):
        async def main():
            async with BridgeHarness(test_thread_ids=None) as h:
                status, head, body = await self.post(h.port)
                self.assertEqual(status, 200)
                self.assertIn("cache-control: no-store", head)
                self.assertEqual(set(body), {"ticket", "expires_in"})
                self.assertEqual(body["expires_in"], 60)
                self.assertGreaterEqual(len(body["ticket"]), 43)   # token_urlsafe(32)
                async with self.dial(h.port, body["ticket"]) as ws:
                    app = AppClient(ws)
                    await app.call("session.resume", session_id=CRON)
                    receipt = await app.call("prompt.submit", session_id=CRON, submission_id="s", text="x")
                    self.assertEqual(receipt["result"]["outcome"], "admitted")
        run(main())

    def test_ticket_is_single_use(self):
        async def main():
            async with BridgeHarness() as h:
                _, _, body = await self.post(h.port)
                async with self.dial(h.port, body["ticket"]):
                    pass
                await self.assert_refused(h.port, body["ticket"])
        run(main())

    def test_ticket_expires_after_its_ttl(self):
        async def main():
            async with BridgeHarness() as h:
                clock = Clock()
                h.bridge.tickets = wsbridge.TicketStore(clock=clock)
                _, _, late = await self.post(h.port)
                _, _, on_time = await self.post(h.port)
                clock.now += 59
                async with self.dial(h.port, on_time["ticket"]):
                    pass
                clock.now += 1
                await self.assert_refused(h.port, late["ticket"])
                self.assertEqual(h.bridge.tickets.live(), 0, "expired tickets do not pile up")
        run(main())

    def test_unknown_and_repeated_ticket_parameters_are_refused(self):
        async def main():
            async with BridgeHarness() as h:
                await self.assert_refused(h.port, "not-a-ticket")
                _, _, one = await self.post(h.port)
                _, _, two = await self.post(h.port)
                await self.assert_refused(h.port, f"{one['ticket']}&ticket={two['ticket']}")
                self.assertEqual(h.gateway.minted, [])
        run(main())

    def test_mint_needs_the_bearer_key(self):
        async def main():
            async with BridgeHarness() as h:
                for key in (None, "wrong"):
                    status, _, body = await self.post(h.port, key=key)
                    self.assertEqual(status, 401)
                    self.assertNotIn(b"ticket", body)
                self.assertEqual(h.bridge.tickets.live(), 0)
        run(main())

    def test_request_split_across_packets_still_mints(self):
        def bytewise(raw):
            return [raw[:3], raw[3:10], raw[10:30], raw[30:]]

        async def main():
            async with BridgeHarness() as h:
                status, _, body = await self.post(h.port, chunks=bytewise)
                self.assertEqual(status, 200)
                async with self.dial(h.port, body["ticket"]):
                    pass
        run(main())

    def test_bearer_header_path_stays_and_spends_no_ticket(self):
        async def main():
            async with BridgeHarness() as h:
                _, _, body = await self.post(h.port)
                async with self.dial(h.port, body["ticket"], {"Authorization": f"Bearer {BEARER}"}):
                    pass
                async with self.dial(h.port, body["ticket"]):   # still unspent
                    pass
        run(main())

    def test_answer_carries_nothing_derived_from_the_key_and_logs_no_ticket(self):
        async def main():
            async with BridgeHarness() as h:
                with self.assertLogs(wsbridge.log, "INFO") as logs:
                    _, _, body = await self.post(h.port)
                    await self.assert_refused(h.port, "wrong-ticket-value")
                    async with self.dial(h.port, body["ticket"]):
                        pass
                    await self.assert_refused(h.port, body["ticket"])
                text = "\n".join(logs.output)
                self.assertNotIn(body["ticket"], text)
                self.assertNotIn("wrong-ticket-value", text)
                self.assertNotIn(BEARER, text)
                self.assertIn(wsbridge.ticket_digest(body["ticket"])[:8], text)
                self.assertNotIn(BEARER, json.dumps(body))
                # Two mints under one key share nothing: random, not derived.
                _, _, again = await self.post(h.port)
                self.assertNotEqual(again["ticket"], body["ticket"])
        run(main())

    def test_other_non_get_requests_stay_refused_without_noise(self):
        async def main():
            async with BridgeHarness() as h:
                reader, writer = await asyncio.open_connection("127.0.0.1", h.port)
                writer.write(b"POST /api/bridge/ws HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
                await writer.drain()
                self.assertNotIn(b"200", await asyncio.wait_for(reader.read(), 5))
                writer.close()
                self.assertEqual(h.bridge.tickets.live(), 0)
        run(main())


class Reconnect(unittest.TestCase):
    def test_drop_rediscovers_remints_and_replays_resume(self):
        async def main():
            async with BridgeHarness() as h, h.app() as app:
                await app.call("session.resume", session_id=ALIAS)
                self.assertEqual((h.discovered, len(h.gateway.minted)), (1, 1))
                # the first ticket is long expired by the time the owner drops us (restart / drain)
                h.clock.now += 120
                h.gateway.instance = "inst-2"
                await h.gateway.drop(1013)
                note = await app.until_event(lambda f: f.get("method") == "bridge.resumed")
                self.assertEqual(note["params"]["session_id"], ROOT)
                self.assertEqual(note["params"]["result"]["execution_generation"], 7)
                self.assertEqual(h.discovered, 2)
                tickets = [t for t, _, _ in h.gateway.minted]
                self.assertEqual(len(tickets), 2)
                self.assertNotEqual(tickets[0], tickets[1])
                # the replayed resume ran on the new connection before anything else
                self.assertEqual([(n, m) for n, m, _ in h.gateway.seen if n == 2][0], (2, "session.resume"))
                receipt = await app.call("prompt.submit", session_id=ALIAS, submission_id="s2", text="again")
                self.assertEqual(receipt["result"]["outcome"], "admitted")
        run(main())

    def test_cached_ticket_would_be_refused(self):
        """Guard on the fake itself: a reused ticket is refused like core's single-use store."""
        clock = Clock()
        gw = FakeGateway(clock)
        gw.port = 1
        ticket = gw.mint(None, gw.endpoint(), subject="s")
        self.assertTrue(gw.redeem(ticket))
        self.assertFalse(gw.redeem(ticket))
        late = gw.mint(None, gw.endpoint(), subject="s")
        clock.now += 31
        self.assertFalse(gw.redeem(late))

    def test_unavailable_owner_is_never_dialed_with_none(self):
        async def main():
            calls = []

            @contextlib.asynccontextmanager
            async def spy(endpoint=None, subject=None):
                calls.append(endpoint)
                raise AssertionError("must not dial")
                yield

            async with BridgeHarness() as h:
                h.discover_ok = False
                h.bridge.connect = spy
                h.bridge.request_wait = 0.3
                async with h.app() as app:
                    reply = await app.call("session.resume", session_id=ROOT)
                    self.assertEqual(reply["error"]["message"], "upstream_unavailable")
                self.assertEqual(calls, [])
                self.assertGreaterEqual(h.discovered, 1)
        run(main())


class ProbeAllowlist(unittest.TestCase):
    def test_unlisted_session_may_resume_but_not_write(self):
        async def main():
            async with BridgeHarness() as h, h.app() as app:
                resumed = await app.call("session.resume", session_id=PROD)
                self.assertEqual(resumed["result"]["session_id"], PROD)
                for method, extra in (("prompt.submit", {"submission_id": "x", "text": "hi"}),
                                      ("session.steer", {"text": "hi", "execution_generation": 7}),
                                      ("session.interrupt", {"execution_generation": 7}),
                                      ("approval.respond", {"execution_generation": 7, "prompt_id": "p",
                                                            "choice": "once"}),
                                      ("clarify.respond", {"execution_generation": 7, "prompt_id": "p",
                                                           "answer": "a"})):
                    reply = await app.call(method, session_id=PROD, **extra)
                    self.assertEqual(reply["error"]["code"], 4001, method)
                    self.assertEqual(reply["error"]["message"], "session_not_allowlisted")
                self.assertEqual([m for _, m, _ in h.gateway.seen], ["session.resume"])
                self.assertEqual(h.gateway.messages, {})
        run(main())

    def test_empty_allowlist_blocks_the_test_thread_too(self):
        async def main():
            async with BridgeHarness(test_thread_ids=()) as h, h.app() as app:
                await app.call("session.resume", session_id=ROOT)
                reply = await app.call("prompt.submit", session_id=ROOT, submission_id="s", text="x")
                self.assertEqual(reply["error"]["message"], "session_not_allowlisted")
        run(main())

    def test_session_created_on_this_connection_may_submit(self):
        async def main():
            async with BridgeHarness(test_thread_ids=()) as h, h.app() as app:
                sid = (await app.call("session.create"))["result"]["session_id"]
                receipt = await app.call("prompt.submit", session_id=sid, submission_id="s", text="x")
                self.assertEqual(receipt["result"]["outcome"], "admitted")
        run(main())


class Config(unittest.TestCase):
    def test_load_config_reads_thread_allowlist(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "app-wsbridge.json")
            with open(path, "w") as f:
                json.dump({"port": 8650, "test_thread_ids": [TEST_THREAD, 1600000000000000002]}, f)
            cfg = wsbridge.load_config(path)
            self.assertEqual(cfg["test_thread_ids"], frozenset({TEST_THREAD, "1600000000000000002"}))
            self.assertEqual(cfg["host"], "127.0.0.1")
            self.assertEqual(cfg["port"], 8650)

    def test_missing_config_means_no_thread_limit(self):
        cfg = wsbridge.load_config("/nonexistent/app-wsbridge.json")
        self.assertIsNone(cfg["test_thread_ids"])

    def test_absent_key_is_no_limit_but_an_empty_list_is_one(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "app-wsbridge.json")
            with open(path, "w") as f:
                json.dump({"port": 8650}, f)
            self.assertIsNone(wsbridge.load_config(path)["test_thread_ids"])
            with open(path, "w") as f:
                json.dump({"test_thread_ids": []}, f)
            self.assertEqual(wsbridge.load_config(path)["test_thread_ids"], frozenset())


class MayWriteBySource(unittest.TestCase):
    def may(self, sid, **kwargs):
        bridge = wsbridge.Bridge(key=BEARER, thread_of=THREADS.get, source_of=SOURCES.get, **kwargs)
        return asyncio.run(bridge.may_write(sid))

    def test_no_thread_limit_opens_every_foreign_source(self):
        self.assertTrue(self.may(PROD))
        self.assertTrue(self.may(CRON), "a foreign session needs no thread")

    def test_http_owned_and_unknown_sources_are_refused(self):
        self.assertFalse(self.may(API))
        self.assertFalse(self.may(ROOM))
        self.assertFalse(self.may("20261101_000000_gone0001"))

    def test_thread_limit_narrows_foreign_but_never_widens(self):
        self.assertTrue(self.may(ROOT, test_thread_ids=(TEST_THREAD,)))
        self.assertFalse(self.may(PROD, test_thread_ids=(TEST_THREAD,)))
        self.assertFalse(self.may(CRON, test_thread_ids=(TEST_THREAD,)))
        with_thread = wsbridge.Bridge(key=BEARER, test_thread_ids=(TEST_THREAD,), thread_of=lambda _s: TEST_THREAD,
                                      source_of=SOURCES.get)
        self.assertFalse(asyncio.run(with_thread.may_write(API)))

    def test_state_db_lookups_read_real_rows(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state.db")
            con = sqlite3.connect(path)
            con.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, thread_id TEXT)")
            con.execute("INSERT INTO sessions VALUES (?, 'cron', NULL), (?, 'api_server', NULL)", (CRON, API))
            con.commit()
            con.close()
            bridge = wsbridge.Bridge(key=BEARER, thread_of=wsbridge.state_db_thread_of(path),
                                     source_of=wsbridge.state_db_source_of(path))
            self.assertTrue(asyncio.run(bridge.may_write(CRON)))
            self.assertFalse(asyncio.run(bridge.may_write(API)))
            self.assertFalse(asyncio.run(bridge.may_write("nope")))

    def test_submit_reaches_a_threadless_foreign_session_end_to_end(self):
        async def main():
            async with BridgeHarness(test_thread_ids=None) as h, h.app() as app:
                await app.call("session.resume", session_id=CRON)
                receipt = await app.call("prompt.submit", session_id=CRON, submission_id="s", text="x")
                self.assertEqual(receipt["result"]["outcome"], "admitted")
                await app.call("session.resume", session_id=API)
                refused = await app.call("prompt.submit", session_id=API, submission_id="t", text="x")
                self.assertEqual(refused["error"]["message"], "session_not_allowlisted")
        run(main())

    def test_core_cron_refusal_reaches_the_app_untouched(self):
        async def main():
            async with BridgeHarness(test_thread_ids=None) as h, h.app() as app:
                await app.call("session.resume", session_id=CRON)
                receipt = await app.call("prompt.submit", session_id=CRON, submission_id="s", text="x")
                self.assertNotIn("error", receipt, "the bridge lets the submit through; core does the refusing")
                self.assertIn(("prompt.submit", CRON), [(m, p.get("session_id")) for _, m, p in h.gateway.seen])
                done = await app.until_event(lambda f: f.get("method") == "event"
                                             and f["params"]["type"] == "message.complete")
                self.assertEqual(done["params"]["payload"], CRON_REFUSAL)
        run(main())


if __name__ == "__main__":
    unittest.main()
