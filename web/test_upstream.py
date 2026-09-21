#!/usr/bin/env python3
"""AUDIT-18/19 reverse-proxy regression suite (real asserts, plain asyncio).

    python3 web/test_upstream.py            # run the suite (exit 0 = green)
    python3 web/test_upstream.py --serve    # legacy manual fake upstream (:8799)

Every test runs serve.build_app() in-process against a fake upstream on an
ephemeral port and monkeypatches serve's tuning globals (restored after).
Red-on-old notes live in each test; invariants guarding wave-1 behaviour
(AUDIT-10) are allowed to be green on old code per the wave-2 rules.
"""
import asyncio
import contextlib
import pathlib
import socket
import sys
import time
import traceback

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from aiohttp import web, ClientSession, ClientTimeout  # noqa: E402

# Import hygiene (ENVHYGIENE §7.2): a temp selector so importing serve can
# NEVER read the operator's real ~/.hermes/.env — non-secret defaults come
# from safe fallbacks, keys come from each harness's own tmp file.
import os as _os, tempfile as _tf
if not (_os.environ.get("HERMES_ENV_FILE") or "").strip():
    _env_probe = _tf.NamedTemporaryFile(
        mode="w", suffix=".env", delete=False, prefix="serve-import-")
    _env_probe.write("API_SERVER_KEY=\n")
    _env_probe.close()
    _os.environ["HERMES_ENV_FILE"] = _env_probe.name
import serve  # noqa: E402

MB = 1024 * 1024
GLOBAL_DEFAULTS = ("MAX_BODY_BYTES", "BIG_STREAM_BYTES", "UPLOAD_IDLE_TIMEOUT",
                   "_API_HEADER_TIMEOUT", "_API_READ_TIMEOUT")


def rss_bytes():
    with open("/proc/self/statm") as f:
        return int(f.read().split()[1]) * 4096


def live_tasks():
    """tasks whose stack actually runs through serve.py (aiohttp's idle
    keep-alive RequestHandler tasks are not our leaks)."""
    out = set()
    for t in asyncio.all_tasks():
        if t is asyncio.current_task():
            continue
        stack, seen = [t.get_coro()], set()
        hit = False
        while stack and not hit:
            c = stack.pop()
            if c is None or id(c) in seen:
                continue
            seen.add(id(c))
            frame = getattr(c, "cr_frame", None) or getattr(c, "gi_frame", None)
            while frame is not None:
                if frame.f_code.co_filename == serve.__file__:
                    hit = True
                    break
                frame = frame.f_back
            inner = getattr(c, "cr_await", None)
            if asyncio.iscoroutine(inner):
                stack.append(inner)
        if hit:
            out.add(t)
    return out


class Harness:
    """fake upstream + proxy on ephemeral ports; serve.API repointed."""

    def __init__(self, fake):
        self.fake = fake
        self.saved = {k: getattr(serve, k) for k in GLOBAL_DEFAULTS
                      if hasattr(serve, k)}
        for k in GLOBAL_DEFAULTS:
            if not hasattr(serve, k):
                setattr(serve, k, {"MAX_BODY_BYTES": 600 * MB,
                                   "BIG_STREAM_BYTES": 8 * MB,
                                   "UPLOAD_IDLE_TIMEOUT": 300.0,
                                   "_API_HEADER_TIMEOUT": 30.0,
                                   "_API_READ_TIMEOUT": 120.0}[k])
        self.saved_api = serve.API

    async def __aenter__(self):
        self.frunner = web.AppRunner(self.fake)
        await self.frunner.setup()
        await web.TCPSite(self.frunner, "127.0.0.1", 0).start()
        self.fake_url = f"http://127.0.0.1:{self.frunner.addresses[0][1]}"
        serve.API = self.fake_url
        if hasattr(serve, "build_app"):
            app = serve.build_app()
        else:  # old serve.py (red runs): assemble the same route table
            app = web.Application(client_max_size=0)
            app.on_startup.append(serve.on_startup)
            app.on_cleanup.append(serve.on_cleanup)
            app.router.add_get("/healthz", serve.healthz)
            for route in ("/health", "/api/{tail:.*}", "/v1/{tail:.*}"):
                app.router.add_route("*", route, serve.api_proxy)
            app.router.add_get("/", serve.static_handler)
            app.router.add_get("/{path:.*}", serve.static_handler)
        self.pr = web.AppRunner(app)
        await self.pr.setup()
        await web.TCPSite(self.pr, "127.0.0.1", 0).start()
        self.proxy_port = self.pr.addresses[0][1]
        self.client = ClientSession(timeout=ClientTimeout(total=None, connect=5))
        return self

    async def __aexit__(self, *exc):
        await self.client.close()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(self.pr.cleanup(), 10)
        with contextlib.suppress(Exception):
            await self.frunner.cleanup(force=True)
        for k, v in self.saved.items():
            setattr(serve, k, v)
        serve.API = self.saved_api


def raw_client(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.setblocking(False)
    return s


async def sock_read(s, want=0, deadline=10.0):
    """read until headers + want bytes of body, or EOF/reset/deadline."""
    loop = asyncio.get_running_loop()
    buf, hdr_end = b"", None
    end = time.monotonic() + deadline
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0:
            break
        try:
            data = await asyncio.wait_for(loop.sock_recv(s, 65536), remaining)
        except (asyncio.TimeoutError, ConnectionResetError, ConnectionError, OSError):
            break
        if not data:
            break
        buf += data
        if hdr_end is None:
            i = buf.find(b"\r\n\r\n")
            if i >= 0:
                hdr_end = i + 4
        if hdr_end is not None and len(buf) - hdr_end >= want:
            break
    return buf


async def wait_quiet(seconds=3.0):
    """drain/handler/connection tasks must all be gone — zombie check."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not live_tasks():
            return
        await asyncio.sleep(0.05)
    pending = ", ".join(repr(t) for t in live_tasks())
    raise AssertionError(f"zombie task(s) still alive: {pending}")


# ----------------------------------------------------------------- tests ---

async def test_streamed_upload_bounded_buffer():
    """AUDIT-18 upload half: an 8MB body must stream through with a bounded
    resident buffer and the upstream must see bytes WHILE the client is
    still sending. Red on old code: request.read() hoarded all 8MB first
    (RSS spike) and the upstream only saw data after the client finished."""
    f = {"first": None, "total": 0}

    async def echo(request):
        n = 0
        async for chunk in request.content.iter_any():
            if f["first"] is None:
                f["first"] = time.monotonic()
            n += len(chunk)
        f["total"] = n
        return web.json_response({"received": n})

    fake = web.Application()
    fake.router.add_route("*", "/api/echo", echo)
    async with Harness(fake) as h:
        samples, stop = [rss_bytes()], asyncio.Event()

        async def sampler():
            while not stop.is_set():
                samples.append(rss_bytes())
                await asyncio.sleep(0.02)

        samp = asyncio.ensure_future(sampler())
        base = samples[0]

        async def body():
            for _ in range(32):
                await asyncio.sleep(0.03)
                yield b"u" * (256 * 1024)
            f["client_done"] = time.monotonic()

        async with h.client.post(f"http://127.0.0.1:{h.proxy_port}/api/echo",
                                 data=body()) as resp:
            j = await resp.json()
        stop.set()
        await samp
        assert j["received"] == 8 * MB == f["total"], f"body corrupted: {j}"
        peak = max(samples) - base
        assert peak < 6 * MB, f"proxy buffer not bounded: peak +{peak // 1024}KiB"
        assert f["first"] < f["client_done"] - 0.3, \
            "upstream only saw the body after the client finished: not streaming"


async def test_declared_oversize_413_before_read():
    """AUDIT-18 cap half #1: a declared Content-Length above MAX_BODY_BYTES
    gets 413 without a single body byte read and without touching the
    upstream. Red on old code: request.read() blocked forever here (the
    client sends no body), no 413 within the deadline."""
    calls = []

    async def sink(request):
        calls.append(request)
        await request.read()
        return web.json_response({})

    fake = web.Application()
    fake.router.add_route("*", "/api/sink", sink)
    async with Harness(fake) as h:
        serve.MAX_BODY_BYTES = 1 * MB
        s = raw_client(h.proxy_port)
        try:
            s.sendall(b"POST /api/sink HTTP/1.1\r\nHost: x\r\n"
                      b"Content-Type: application/octet-stream\r\n"
                      b"Content-Length: 2097152\r\n\r\n")
            t0 = time.monotonic()
            head = await sock_read(s)
            assert b" 413 " in head, f"no prompt 413: {head[:64]!r}"
            assert time.monotonic() - t0 < 2.0, "413 arrived late: body was read first"
        finally:
            s.close()
        assert not calls, "oversized upload reached the upstream"


async def test_undeclared_oversize_413():
    """AUDIT-18 cap half #2: a chunked (length-unknown) upload is refused
    the moment streamed bytes cross the cap, not after landing fully.
    Red on old code: the full 1.2MB was buffered, forwarded, 200 back."""
    fake = web.Application()

    async def sink(request):
        with contextlib.suppress(Exception):
            async for _ in request.content.iter_any():
                pass
        return web.json_response({})

    fake.router.add_route("*", "/api/sink", sink)
    async with Harness(fake) as h:
        serve.MAX_BODY_BYTES = 1 * MB
        s = raw_client(h.proxy_port)
        try:
            s.sendall(b"POST /api/sink HTTP/1.1\r\nHost: x\r\n"
                      b"Transfer-Encoding: chunked\r\n\r\n")
            frame = b"40000\r\n" + b"z" * (256 * 1024) + b"\r\n"
            for _ in range(5):  # 1.25MB total, cap is 1MB
                try:
                    s.sendall(frame)
                except OSError:
                    break  # proxy already refused and hung up
                await asyncio.sleep(0.1)
            head = await sock_read(s)
            assert b" 413 " in head, f"crossing the cap went unrefused: {head[:64]!r}"
        finally:
            s.close()


async def test_sse_drain_not_degraded():
    """AUDIT-18 guard / wave-1 invariant (green on old code by rule):
    client vanishes mid-SSE; the drain must keep the upstream stream fed to
    completion, upstream must never see a disconnect, drain task must end."""
    st = {"events": 0, "err": None, "completed": False}

    async def sse(request):
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
        await resp.prepare(request)
        try:
            for i in range(6):
                await resp.write(f"event: tick\ndata: {i}\n\n".encode())
                st["events"] += 1
                await asyncio.sleep(0.15)
            await resp.write_eof()
            st["completed"] = True
        except Exception as e:  # a drain failure shows up right here
            st["err"] = repr(e)
        return resp

    fake = web.Application()
    fake.router.add_get("/api/sse", sse)
    async with Harness(fake) as h:
        s = raw_client(h.proxy_port)
        s.sendall(b"GET /api/sse HTTP/1.1\r\nHost: x\r\n"
                  b"Accept: text/event-stream\r\nConnection: close\r\n\r\n")
        got = await sock_read(s, want=64)
        assert b"event: tick" in got, "SSE never reached the client"
        s.close()  # browser tab gone
        end = time.monotonic() + 6
        while not st["completed"] and st["err"] is None and time.monotonic() < end:
            await asyncio.sleep(0.05)
        assert st["err"] is None, f"upstream saw the disconnect: {st['err']}"
        assert st["completed"] and st["events"] == 6, "run did not survive the detach"
        end = time.monotonic() + 3
        while serve._drainers and time.monotonic() < end:
            await asyncio.sleep(0.05)
        assert not serve._drainers, "drain task never finished"
        await wait_quiet()


async def test_client_gone_mid_download_no_zombie():
    """AUDIT-19 download half: client dies mid-body — upstream must be
    closed (fake sees the abort), no drain may be spawned for non-SSE, no
    zombie tasks. Red on old code: upstream.read() always completed (fake
    recorded 'complete', 32MB resident in the proxy)."""
    st = {"result": None}

    async def big(request):
        resp = web.StreamResponse(headers={"Content-Type": "application/octet-stream"})
        await resp.prepare(request)
        try:
            for _ in range(500):  # 32MB, slower than a LAN
                await resp.write(b"d" * 65536)
                await asyncio.sleep(0.002)
            await resp.write_eof()
            st["result"] = "complete"
        except Exception as e:
            st["result"] = f"aborted:{type(e).__name__}"
        return resp

    fake = web.Application()
    fake.router.add_get("/api/big", big)
    async with Harness(fake) as h:
        s = raw_client(h.proxy_port)
        s.sendall(b"GET /api/big HTTP/1.1\r\nHost: x\r\n\r\n")
        got = await sock_read(s, want=200000, deadline=15)
        assert len(got) > 1000, "download never started"
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
        s.close()  # hard RST, like a killed tab
        end = time.monotonic() + 6
        while st["result"] is None and time.monotonic() < end:
            await asyncio.sleep(0.05)
        assert st["result"] and st["result"].startswith("aborted"), \
            f"upstream not closed on client death: {st['result']}"
        assert not serve._drainers, "non-SSE disconnect must not spawn a drain"
        await wait_quiet()


async def test_big_stream_concurrency_quota():
    """AUDIT-18 quota: >8MiB streams serialise through BIG_STREAM_SLOTS.
    4 concurrent 8MB downloads must finish in ~2 waves, and the semaphore
    must be fully held mid-flight. Red on old code: no quota existed
    (serve.big_streams missing -> AttributeError; with buffering, all four
    finish in one wave)."""
    serve.BIG_STREAM_SLOTS = 2
    fake = web.Application()

    async def big(request):
        resp = web.StreamResponse(headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(8 * MB)})
        await resp.prepare(request)
        with contextlib.suppress(Exception):
            for _ in range(128):
                await resp.write(b"q" * 65536)
                await asyncio.sleep(0.015)
        return resp

    fake.router.add_get("/api/big", big)
    async with Harness(fake) as h:
        serve.BIG_STREAM_BYTES = 1 * MB  # 8MB downloads qualify
        serve.big_streams = asyncio.Semaphore(serve.BIG_STREAM_SLOTS)
        held_peak, done_t, stop = [0], {}, asyncio.Event()

        async def watcher():
            while not stop.is_set():
                held_peak[0] = max(held_peak[0],
                                   serve.BIG_STREAM_SLOTS - serve.big_streams._value)
                await asyncio.sleep(0.02)

        w = asyncio.ensure_future(watcher())

        async def grab(i):
            async with h.client.get(f"http://127.0.0.1:{h.proxy_port}/api/big") as r:
                assert r.status == 200
                n = 0
                async for chunk in r.content.iter_any():
                    if n == 0:
                        done_t[i] = time.monotonic()
                    n += len(chunk)
            assert n == 8 * MB, f"stream {i} truncated: {n}"

        t0 = time.monotonic()
        await asyncio.gather(*(grab(i) for i in range(4)))
        stop.set()
        await w
        assert held_peak[0] == serve.BIG_STREAM_SLOTS, "quota never engaged"
        # a stream blocked on the quota cannot have produced a first byte;
        # without the quota all four first-bytes land within a few ms.
        spread = max(done_t.values()) - min(done_t.values())
        assert spread > 1.0, \
            f"all big streams ran at once (first-byte spread {spread:.2f}s): no quota"
        assert time.monotonic() - t0 < 30


async def test_audit10_timeouts_intact():
    """wave-1 invariant (green on old code by rule): wedged headers -> 504
    after _API_HEADER_TIMEOUT; headers-ok-then-body-wedged -> clean 504."""
    async def slow_headers(request):
        await asyncio.sleep(30)
        return web.json_response({})

    async def wedge_body(request):
        resp = web.StreamResponse()
        await resp.prepare(request)
        await asyncio.sleep(30)
        return resp

    fake = web.Application()
    fake.router.add_get("/api/late", slow_headers)
    fake.router.add_get("/api/wedge", wedge_body)
    async with Harness(fake) as h:
        serve._API_HEADER_TIMEOUT = 1.0
        serve._API_READ_TIMEOUT = 1.0
        async with h.client.get(f"http://127.0.0.1:{h.proxy_port}/api/late") as r:
            body = await r.text()
            assert r.status == 504 and "header" in body, f"{r.status} {body!r}"
        async with h.client.get(f"http://127.0.0.1:{h.proxy_port}/api/wedge") as r:
            body = await r.text()
            assert r.status == 504 and "read" in body, f"{r.status} {body!r}"


async def test_slow_upload_beats_header_deadline():
    """AUDIT-10 must NOT bite uploads: bytes still flowing means alive.
    3s paced upload with _API_HEADER_TIMEOUT=0.3 must still land 200.
    Green on old code (upload happened inside request.read(), outside the
    stopwatch) — guards the streaming rewrite against naively reusing the
    30s deadline for the upload phase."""
    async def echo(request):
        n = 0
        async for chunk in request.content.iter_any():
            n += len(chunk)
        return web.json_response({"received": n})

    fake = web.Application()
    fake.router.add_route("*", "/api/echo", echo)
    async with Harness(fake) as h:
        serve._API_HEADER_TIMEOUT = 0.3

        async def body():
            for _ in range(20):
                await asyncio.sleep(0.15)
                yield b"s" * 65536

        async with h.client.post(f"http://127.0.0.1:{h.proxy_port}/api/echo",
                                 data=body()) as r:
            j = await r.json()
        assert r.status == 200 and j["received"] == 20 * 65536, \
            f"client-paced upload punished by header deadline: {r.status} {j}"


async def test_stalled_upload_cut():
    """client stops sending entirely: UPLOAD_IDLE_TIMEOUT cuts it with a 504
    instead of holding the upstream connection forever. Cannot exist on
    old code (request.read() had no deadline at all — this test would just
    time out failing there)."""
    st = {"got": 0, "gone": False}

    async def sink(request):
        with contextlib.suppress(Exception):
            async for chunk in request.content.iter_any():
                st["got"] += len(chunk)
        st["gone"] = True
        return web.json_response({})

    fake = web.Application()
    fake.router.add_route("*", "/api/sink", sink)
    async with Harness(fake) as h:
        serve.UPLOAD_IDLE_TIMEOUT = 1.0
        s = raw_client(h.proxy_port)
        try:
            s.sendall(b"POST /api/sink HTTP/1.1\r\nHost: x\r\n"
                      b"Content-Type: application/octet-stream\r\n"
                      b"Content-Length: 2097152\r\n\r\n")
            s.sendall(b"t" * 65536)  # then: silence forever
            t0 = time.monotonic()
            head = await sock_read(s)
            assert b" 504 " in head, f"stalled upload never cut: {head[:64]!r}"
            assert time.monotonic() - t0 < 6, "idle cut took forever"
            end = time.monotonic() + 4
            while not st["gone"] and time.monotonic() < end:
                await asyncio.sleep(0.05)
            assert st["got"] == 65536 and st["gone"], "aborted upload leaked upstream"
        finally:
            s.close()
        await wait_quiet()


TESTS = [
    test_streamed_upload_bounded_buffer,
    test_declared_oversize_413_before_read,
    test_undeclared_oversize_413,
    test_sse_drain_not_degraded,
    test_client_gone_mid_download_no_zombie,
    test_big_stream_concurrency_quota,
    test_audit10_timeouts_intact,
    test_slow_upload_beats_header_deadline,
    test_stalled_upload_cut,
]


async def run_suite():
    failed = []
    for t in TESTS:
        t0 = time.monotonic()
        try:
            await asyncio.wait_for(t(), 90)
            print(f"PASS {t.__name__} ({time.monotonic() - t0:.1f}s)")
        except BaseException:
            print(f"FAIL {t.__name__} ({time.monotonic() - t0:.1f}s)")
            traceback.print_exc()
            failed.append(t.__name__)
        await asyncio.sleep(0.1)
    print(f"\n{len(TESTS) - len(failed)}/{len(TESTS)} passed")
    return 1 if failed else 0


# ---------------------------------------------------------- legacy serve ---

async def _manual_sse(request):
    resp = web.StreamResponse(headers={"content-type": "text/event-stream"})
    await resp.prepare(request)
    for i in range(5):
        await resp.write(f"event: tick\ndata: {i}\n\n".encode())
        await asyncio.sleep(0.4)
    await resp.write_eof()
    return resp


async def _manual_slow(request):
    await asyncio.sleep(3)
    return web.json_response({"late": True})


if __name__ == "__main__":
    if "--serve" in sys.argv:
        app = web.Application()
        app.router.add_get("/v1/stream", _manual_sse)
        app.router.add_get("/v1/slow", _manual_slow)
        web.run_app(app, host="127.0.0.1", port=8799, print=None, access_log=None)
    else:
        sys.exit(asyncio.run(run_suite()))
