#!/usr/bin/env python3
"""Hermes Web 發佈站：靜態 Flutter web 產物 + API server 反代（同源免 CORS）。

/api/* 與 /v1/* 原樣轉發到 hermes API server（含 SSE 串流），其餘路徑走
web/current/（repo-relative）下的靜態檔。純 stdlib+aiohttp（借用 hermes venv）。

Bind 介面由部署者選定：未設定時只綁 loopback，绝不預設公開介面；要讓其它
網路碰到本站，必須明確設定 HERMES_WEB_HOST（並自行負責入口信任與 TLS）。
"""
import asyncio
import logging
import os
import pathlib
import sys

from aiohttp import ClientResponse, ClientSession, ClientTimeout, web

_REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "scripts"))
import runtime_config  # noqa: E402

# Runtime config (ENVHYGIENE §4.3): process env > selected env file > safe
# defaults. Values are NON-SECRET only; the API key is read from the file
# per request (see _api_server_key). Names outside this allowlist are never
# pulled from the file.
_CFG = runtime_config.Resolver()
_ALLOW = {"HERMES_WEB_API", "HERMES_WEB_HOST", "HERMES_WEB_PORT",
          "HERMES_WEB_ROOT", "HERMES_WEB_HOME", "HERMES_PROXY_MAX_BODY",
          "HERMES_PROXY_BIG_SLOTS"}


def _cfg(name: str, default: str) -> str:
    return _CFG.resolve(name, default=default, allowlist=_ALLOW)


CONFIG_ERRORS: list[str] = []


def _pos_int(name: str, raw: str, default: int) -> int:
    try:
        value = int(raw)
    except ValueError:
        CONFIG_ERRORS.append(f"{name}: not an integer")
        return default
    if value <= 0:
        CONFIG_ERRORS.append(f"{name}: must be positive")
        return default
    return value


ROOT = pathlib.Path(_cfg("HERMES_WEB_ROOT", str(_REPO / "web" / "current")))
API = _cfg("HERMES_WEB_API", "http://127.0.0.1:8642")
# 逗號分隔的 bind 清單；預設只有 loopback。多介面（例如同時給反代前置與
# 私人網路直連）要由部署者明確列出。
HOSTS = [h.strip() for h in _cfg("HERMES_WEB_HOST", "127.0.0.1").split(",")
         if h.strip()]
PORT = _pos_int("HERMES_WEB_PORT", _cfg("HERMES_WEB_PORT", "8700"), 8700)

# 反代時不得透傳的標頭：逐跳標頭 + Origin。
# Origin 拿掉讓 gateway 的 CORS middleware 視為原生 client：瀏覽器 POST 的
# Origin（部署站自己的域名）可能不在 gateway 的 allowlist 而吃 403。安全不
# 受影響：本站與 API 同源、auth 仍靠 Bearer token，且本輪不重設 CORS 行為。
HOP_BY_HOP = {"host", "connection", "keep-alive", "proxy-authenticate",
              "proxy-authorization", "te", "trailers", "transfer-encoding",
              "upgrade", "origin"}

session: ClientSession | None = None
# drain 存活判定：靜默 10 分鐘（gateway 每 30s 一發 keepalive）判卡死放手；
# 6 小時只當最後保險絲，正常長任務不再被時間表砍。
_DRAIN_SILENCE_SECONDS = 600
_DRAIN_MAX_SECONDS = 6 * 3600
# AUDIT-10：非 SSE 反代有應用層截止——headers 30s、response read 120s。
# total=None 是 SSE 長連線的需要，但不能讓普通 API 呼叫在上游卡住時無限
# 轉圈（Tailscale 半斷線／上游殭死）。SSE（Accept: text/event-stream）路徑
# 完全不動：drain 的 silence 判定才是它的存活時鐘。
_API_HEADER_TIMEOUT = 30
_API_READ_TIMEOUT = 120
# AUDIT-18：反代不再全量緩衝上下載，改為串流＋兩道閘門：
# 1) body cap 在讀第一字節前生效（宣告式 Content-Length 超標直接 413；
#    未知長度的 chunked 上傳在串流計數越線時中止）。cap 設在 gateway
#    自家 500MiB 上限之上，正常附件永遠碰不到，只是防 OOM。
# 2) 大檔（>8MiB）串流併發配額：同時最多 2 條。SSE 不佔配額（記憶體
#    開銷近零，且所有權歸 drain 規則）。
MAX_BODY_BYTES = _pos_int("HERMES_PROXY_MAX_BODY", _cfg(
    "HERMES_PROXY_MAX_BODY", str(600 * 1024 * 1024)), 600 * 1024 * 1024)
BIG_STREAM_BYTES = 8 * 1024 * 1024
BIG_STREAM_SLOTS = _pos_int("HERMES_PROXY_BIG_SLOTS", _cfg(
    "HERMES_PROXY_BIG_SLOTS", "2"), 2)
# 上傳階段的擱死上限：客戶端位元組還在流就等於自己計時（等於舊碼
# request.read() 的語意，AUDIT-10 的 30s headers 截止不能套在上傳上）；
# 完全停滯超過這個秒數才掐。
UPLOAD_IDLE_TIMEOUT = 300
_drainers = set()  # strong refs: asyncio only keeps weak refs to tasks
big_streams: asyncio.Semaphore | None = None
log = logging.getLogger("hermes-web")


def _client() -> ClientSession:
    assert session is not None, "session created in on_startup"
    return session


async def _drain_to_end(upstream, why):
    """Browser's gone but the run lives on: keep reading the SSE stream so
    the API server never sees a dropped connection (it interrupts runs on
    disconnect). Liveness, not a stopwatch: the gateway emits a `: keepalive`
    comment every 30s while a run is live, so silence (not elapsed time)
    marks a wedged stream. The old flat 1800s cap killed any run that ran
    longer than 30min while detached (2026-09-18: two runs interrupted at
    exactly +30min04s after the drain's deadline)."""
    log.info("browser left mid-stream (%s); keeping the run alive", why)
    try:
        deadline = asyncio.get_running_loop().time() + _DRAIN_MAX_SECONDS
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                log.warning("drain hit the %ds ceiling; releasing the run",
                            _DRAIN_MAX_SECONDS)
                break
            try:
                chunk = await asyncio.wait_for(
                    upstream.content.read(65536),
                    min(remaining, _DRAIN_SILENCE_SECONDS))
            except TimeoutError:
                # 30s keepalive cadence means 10min of zero bytes = wedged.
                log.warning("no stream traffic for %ds; releasing the run",
                            _DRAIN_SILENCE_SECONDS)
                break
            if not chunk:
                break
    except (asyncio.CancelledError, Exception):
        pass
    finally:
        upstream.release()


def _spawn_drain(upstream, why):
    t = asyncio.create_task(_drain_to_end(upstream, why))
    _drainers.add(t)
    t.add_done_callback(_drainers.discard)


class _BodyTooLarge(Exception):
    """undeclared upload crossed MAX_BODY_BYTES mid-stream (AUDIT-18)."""


def _declared_length(headers) -> int | None:
    try:
        return int(headers.get("Content-Length", ""))
    except ValueError:
        return None


async def _request_body_stream(request: web.Request, prog: dict,
                               done: asyncio.Event, over: asyncio.Event):
    """Feed the client's body upstream as it arrives (chunked, never fully
    resident). prog tracks liveness for the upload-phase stopwatch. When the
    undeclared-length cap trips we stop feeding and flag `over` — we must NOT
    raise from inside the generator: aiohttp's payload writer routes iterator
    exceptions into set_exception(protocol) and the request coroutine can end
    up stranded. Stopping quietly lets the waiter cancel the request task,
    a path that closes every handle cleanly (verified against aiohttp 3.14)."""
    sent = 0
    loop = asyncio.get_running_loop()
    async for chunk in request.content.iter_any():
        sent += len(chunk)
        if sent > MAX_BODY_BYTES:
            prog["over"] = True
            over.set()
            return
        prog["last"] = loop.time()
        yield chunk
    done.set()


async def _request_upload_then_headers(coro, prog: dict, done: asyncio.Event,
                                       over: asyncio.Event):
    """Client-paced upload, then AUDIT-10's header deadline. The bytes flow at
    the client's speed (a slow-but-alive upload is not a timeout — same as the
    old request.read()); once the last byte is handed to the writer, headers
    get the usual 30s. A fully stalled client is cut at UPLOAD_IDLE_TIMEOUT,
    and a cap breach (over) cancels the request task — both so neither can
    hold the upstream connection forever."""
    task = asyncio.ensure_future(coro)
    waiter = asyncio.ensure_future(done.wait())
    overer = asyncio.ensure_future(over.wait())
    loop = asyncio.get_running_loop()
    handed_off = False
    try:
        while not done.is_set() and not over.is_set():
            last = prog["last"] or loop.time()
            timeout = last + UPLOAD_IDLE_TIMEOUT - loop.time()
            if timeout <= 0:
                raise asyncio.TimeoutError()
            finished, _ = await asyncio.wait(
                {task, waiter, overer}, timeout=timeout,
                return_when=asyncio.FIRST_COMPLETED)
            if over.is_set():
                raise _BodyTooLarge()
            if task in finished:
                response = task.result()
                handed_off = True
                return response
            if waiter in finished:
                break
        if over.is_set():
            raise _BodyTooLarge()
        response = await asyncio.wait_for(asyncio.shield(task), _API_HEADER_TIMEOUT)
        if over.is_set():
            raise _BodyTooLarge()
        handed_off = True
        return response
    finally:
        waiter.cancel()
        overer.cancel()
        if not task.done():
            task.cancel()
        try:
            result = await task
        except (asyncio.CancelledError, Exception):
            result = None
        if not handed_off and isinstance(result, ClientResponse):
            result.release()  # completed after our own timeout/cancel


async def _stream_response(request: web.Request, upstream: ClientResponse,
                           resp_headers: dict, _release) -> web.StreamResponse:
    """AUDIT-18: pipe a non-SSE upstream body downstream in bounded chunks —
    backpressure comes free (a slow reader pauses upstream reads instead of
    the proxy hoarding the whole body). AUDIT-10's silence deadline stays on
    every read: before the first byte goes out it's still a clean 504; after
    that the only honest move is killing the truncated connection.
    AUDIT-19: every exit path — EOF, client gone, wedged body, cancellation —
    ends upstream; no half-owned connections."""
    total = _declared_length(upstream.headers)
    slot = total is not None and total > BIG_STREAM_BYTES
    if slot:
        await big_streams.acquire()
    started = False
    finished = False
    streamed = 0
    try:
        async def read_chunk():
            try:
                return await asyncio.wait_for(
                    upstream.content.read(65536), _API_READ_TIMEOUT)
            except asyncio.TimeoutError:
                if started:
                    raise ConnectionResetError("upstream read timeout")
                raise web.HTTPGatewayTimeout(text="upstream read timeout")

        first = await read_chunk()  # before prepare: 504 must stay possible
        resp = web.StreamResponse(status=upstream.status, headers=resp_headers)
        await resp.prepare(request)
        started = True
        if first:
            streamed = len(first)
            await resp.write(first)
        while True:
            chunk = await read_chunk()
            if not chunk:
                break
            if not slot and streamed + len(chunk) > BIG_STREAM_BYTES:
                await big_streams.acquire()
                slot = True
            await resp.write(chunk)
            streamed += len(chunk)
        await resp.write_eof()
        finished = True
        return resp
    finally:
        if slot:
            big_streams.release()
        if not finished:
            _release()


async def api_proxy(request: web.Request) -> web.StreamResponse:
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP}
    # SSE requests are exempt from every application-layer stopwatch (their
    # liveness is the drain's silence clock); plain API calls get bounded
    # header/response-read deadlines so a wedged upstream can't hang forever.
    sse = "text/event-stream" in request.headers.get("Accept", "")
    has_body = request.can_read_body
    declared = request.content_length
    # AUDIT-18: the body cap lands BEFORE a single body byte is read — an
    # oversized declared upload is refused without touching the buffer or the
    # upstream at all (Connection: close so aiohttp doesn't drain it either).
    if has_body and declared is not None and declared > MAX_BODY_BYTES:
        return web.Response(status=413, text="request body too large",
                            headers={"Connection": "close"})
    if has_body:
        # the body is re-chunked as it streams, so its Content-Length cannot
        # travel upstream (mutually exclusive with Transfer-Encoding).
        headers.pop("content-length", None)
        prog = {"last": None, "over": False}
        done = asyncio.Event()
        over = asyncio.Event()
        body = _request_body_stream(request, prog, done, over)
    else:
        prog = None
        done = None
        body = None
    req_coro = _client().request(request.method, API + request.path_qs,
                                 data=body, headers=headers,
                                 allow_redirects=False)
    try:
        if prog is not None and not sse:
            upstream = await _request_upload_then_headers(req_coro, prog, done, over)
        elif sse:
            upstream = await req_coro
        else:
            upstream = await asyncio.wait_for(req_coro, _API_HEADER_TIMEOUT)
    except asyncio.TimeoutError:
        if prog is not None and prog["over"]:
            return web.Response(status=413, text="request body too large",
                                headers={"Connection": "close"})
        raise web.HTTPGatewayTimeout(text="upstream header timeout")
    except BaseException:
        if prog is not None and prog["over"]:
            return web.Response(status=413, text="request body too large",
                                headers={"Connection": "close"})
        raise

    released = False

    def _release():
        nonlocal released
        if not released:
            released = True
            upstream.release()

    try:
        resp_headers = {k: v for k, v in upstream.headers.items()
                        if k.lower() not in HOP_BY_HOP | {"content-encoding", "content-length"}}
        if upstream.content_type == "text/event-stream":
            resp = web.StreamResponse(status=upstream.status, headers=resp_headers)
            resp.headers["X-Accel-Buffering"] = "no"
            try:
                await resp.prepare(request)
                while True:
                    chunk = await upstream.content.read(65536)
                    if not chunk:
                        break
                    await resp.write(chunk)
            except asyncio.CancelledError:
                _spawn_drain(upstream, "client cancelled")
                return resp
            except Exception:
                _spawn_drain(upstream, "write failed")
                return resp
            return resp
        # Only non-event-stream bodies reach here (the SSE branch returned
        # above), so the read deadline is always on.
        return await _stream_response(request, upstream, resp_headers, _release)
    except Exception:
        # SSE paths never reach here (they either finish or hand ownership
        # to a drain task, which releases); non-SSE paths release themselves
        # in _stream_response's finally, so this is the leftovers-only door.
        _release()
        raise


# ---- R3 management endpoints (PATCH skills / memories), special-cased BEFORE
# the generic api_proxy: the gateway has no switch semantics for these, and
# the red line forbids touching hermes source — we only IMPORT its libraries
# (serve.py runs in the hermes venv). Auth: Bearer API_SERVER_KEY from
# ~/.hermes/.env, same key the app already sends on every proxied call.

ENV_FILE = _CFG.path  # the ONE selector resolved by runtime_config (§3.1.1)
# memory files: whitelisted names only, char limits are the agent-side
# conventions (server does NOT gate them; the app warns but can force-save).
MEMORY_FILES = {"MEMORY.md": 2200, "USER.md": 1375}


def _api_server_key() -> str | None:
    # Same strict parser as everything else; quotes agree with the Dart
    # tools. Re-read per request (key rotation stays live); unreadable or
    # malformed => None => fail-closed 401, never a logged value.
    return runtime_config.read_key(ENV_FILE)


def _authorized(request: web.Request) -> bool:
    expected = _api_server_key()
    if not expected:  # unreadable key file: fail closed, never proxy-blind
        return False
    return request.headers.get("Authorization", "") == f"Bearer {expected}"


def _unauthorized() -> web.Response:
    return web.json_response(
        {"error": {"message": "invalid or missing API key"}}, status=401)


def _memories_dir() -> pathlib.Path:
    return pathlib.Path(_cfg(
        "HERMES_WEB_HOME", str(pathlib.Path.home() / ".hermes"))) / "memories"


def _memory_item(name: str) -> dict:
    path = _memories_dir() / name
    try:
        content = path.read_text(encoding="utf-8")
        return {"name": name, "chars": len(content), "limit": MEMORY_FILES[name],
                "content": content, "mtime": path.stat().st_mtime}
    except (OSError, UnicodeDecodeError):
        return {"name": name, "chars": 0, "limit": MEMORY_FILES[name],
                "content": None, "mtime": None}


async def memories_get(request: web.Request) -> web.Response:
    if not _authorized(request):
        return _unauthorized()
    return web.json_response(
        {"object": "list", "files": [_memory_item(n) for n in MEMORY_FILES]})


async def memories_put(request: web.Request) -> web.Response:
    if not _authorized(request):
        return _unauthorized()
    name = request.match_info["name"]
    if "/" in name or "\\" in name or ".." in name:
        return web.json_response(
            {"error": {"message": "invalid file name"}}, status=400)
    if name not in MEMORY_FILES:
        return web.json_response(
            {"error": {"message": "unknown memory file"}}, status=404)
    try:
        body = await request.json()
    except Exception:
        return web.json_response(
            {"error": {"message": "invalid JSON body"}}, status=400)
    content = body.get("content")
    if not isinstance(content, str):  # "" is legal (clears the file)
        return web.json_response(
            {"error": {"message": "content must be a string"}}, status=400)
    target = _memories_dir() / name
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f"{name}.tmp-{os.getpid()}")
    try:
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, target)  # atomic, same-directory
    except OSError as exc:
        try:
            tmp.unlink(missing_ok=True)  # never leave a tmp file behind
        except OSError:
            pass
        return web.json_response(
            {"error": {"message": f"write failed: {exc}"}}, status=500)
    return web.json_response(_memory_item(name))


async def skills_patch(request: web.Request) -> web.Response:
    if not _authorized(request):
        return _unauthorized()
    name = request.match_info["name"]
    try:
        body = await request.json()
    except Exception:
        return web.json_response(
            {"error": {"message": "invalid JSON body"}}, status=400)
    enabled = body.get("enabled")
    if not isinstance(enabled, bool):
        return web.json_response(
            {"error": {"message": "enabled must be a boolean"}}, status=400)
    try:  # hermes libraries; missing/broken backend must land 503, never a 500 crash
        from hermes_cli.config import load_config
        from hermes_cli.skills_config import get_disabled_skills, save_disabled_skills
        from agent.skill_utils import ESSENTIAL_SKILLS
        from tools.skills_tool import _find_all_skills
        installed = {s["name"]: s for s in _find_all_skills(skip_disabled=True)}
    except Exception:
        log.exception("skills backend unavailable")
        return web.json_response(
            {"error": {"message": "skills backend unavailable"}}, status=503)
    if name not in installed:
        return web.json_response(
            {"error": {"message": f"unknown skill: {name}"}}, status=404)
    if not enabled and name in ESSENTIAL_SKILLS:
        return web.json_response(
            {"error": {"message": "essential skills cannot be disabled"}},
            status=400)
    try:
        config = load_config()
        disabled = set(get_disabled_skills(config))
        if enabled:
            disabled.discard(name)
        else:
            disabled.add(name)
        save_disabled_skills(config, disabled)
    except Exception as exc:
        log.exception("save_disabled_skills failed")
        return web.json_response(
            {"error": {"message": f"save failed: {exc}"}}, status=503)
    return web.json_response({
        **installed[name],
        "enabled": enabled,
        "essential": name in ESSENTIAL_SKILLS,
    })


async def static_handler(request: web.Request) -> web.StreamResponse:
    path = request.match_info.get("path") or "index.html"
    target = (ROOT / path).resolve()
    if not str(target).startswith(str(ROOT.resolve())) or not target.is_file():
        return web.FileResponse(ROOT / "index.html")  # SPA 路由回落
    resp = web.FileResponse(target)
    if path == "index.html" or path == "flutter_bootstrap.js":
        resp.headers["Cache-Control"] = "no-cache"  # 發佈即生效
    return resp


async def healthz(_: web.Request) -> web.Response:
    return web.json_response({"ok": True, "root": str(ROOT), "api": API})


async def on_startup(app: web.Application) -> None:
    global session, big_streams
    # total=None：SSE 長連線不能掐表；連線失敗快速回饋。
    session = ClientSession(timeout=ClientTimeout(total=None, connect=10))
    big_streams = asyncio.Semaphore(BIG_STREAM_SLOTS)


async def on_cleanup(_: web.Application) -> None:
    if session is not None:
        await session.close()


def build_app() -> web.Application:
    # client_max_size=0：附件上傳最大 500MB，aiohttp 預設 1MB 會 413。
    # （AUDIT-18：大小閘門改由 api_proxy 在讀前自己把守——MAX_BODY_BYTES
    #  413＋大檔配額——不再靠 aiohttp 全讀後攔截。）
    app = web.Application(client_max_size=0)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app.router.add_get("/healthz", healthz)
    # R3: management endpoints are matched BEFORE the catch-all proxy.
    app.router.add_patch("/api/skills/{name}", skills_patch)
    app.router.add_get("/api/memories", memories_get)
    app.router.add_put("/api/memories/{name}", memories_put)
    app.router.add_route("*", "/health", api_proxy)  # app 的 health 探測走反代
    app.router.add_route("*", "/api/{tail:.*}", api_proxy)
    app.router.add_route("*", "/v1/{tail:.*}", api_proxy)
    app.router.add_get("/", static_handler)
    app.router.add_get("/{path:.*}", static_handler)
    return app


def effective_config() -> list[str]:
    """One line per non-secret setting with its SOURCE (env|file|default);
    values are deployment endpoints, not credentials — the key is only ever
    reported as key_present=... (bool)."""
    lines = []
    for name, value in (
            ("HERMES_WEB_API", API), ("HERMES_WEB_HOST", ",".join(HOSTS)),
            ("HERMES_WEB_PORT", str(PORT)), ("HERMES_WEB_ROOT", str(ROOT)),
            ("HERMES_WEB_HOME", _cfg("HERMES_WEB_HOME",
                                      str(pathlib.Path.home() / ".hermes"))),
            ("HERMES_PROXY_MAX_BODY", str(MAX_BODY_BYTES)),
            ("HERMES_PROXY_BIG_SLOTS", str(BIG_STREAM_SLOTS))):
        lines.append(f"{name}={value} ({_CFG.source(name)})")
    return lines


def check_config(require_auth_key: bool = False) -> list[str]:
    """All problems, none of them leaking values. Empty list => good."""
    problems = list(CONFIG_ERRORS)
    try:
        runtime_config.validate_url(API, name="HERMES_WEB_API")
    except runtime_config.ConfigError as exc:
        problems.append(str(exc))
    if not HOSTS:
        problems.append("HERMES_WEB_HOST: no bind address")
    for host in HOSTS:
        if not host:
            problems.append("HERMES_WEB_HOST: empty entry")
    if not (1 <= PORT <= 65535):
        problems.append("HERMES_WEB_PORT: port out of range")
    if not (ROOT / "index.html").is_file():
        problems.append("HERMES_WEB_ROOT: index.html not found")
    if require_auth_key and not _CFG.key_present():
        problems.append("API_SERVER_KEY: required but not present")
    return problems


def main(argv: list[str]) -> int:
    check = "--check-config" in argv[1:]
    require_key = "--require-auth-key" in argv[1:]
    if check:
        problems = check_config(require_key)
        for line in effective_config():
            print(line)
        print(f"env_file_readable={_CFG.exists} key_present={_CFG.key_present()}")
        if problems:
            for p in problems:
                print(f"CONFIG ERROR: {p}", file=sys.stderr)
            return 1
        print("CONFIG OK")
        return 0
    problems = check_config(require_key)
    if problems:
        for p in problems:
            print(f"CONFIG ERROR: {p}", file=sys.stderr)
        return 1
    app = build_app()

    async def run() -> None:
        # 開 access log（stderr → journald）：之前是 None，瀏覽器進不進得來無法追查
        logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                            format="%(asctime)s %(levelname)s %(message)s")
        for line in effective_config():
            print(line, file=sys.stderr)
        runner = web.AppRunner(app)
        await runner.setup()
        try:
            for host in HOSTS:
                await web.TCPSite(runner, host, PORT).start()
        except OSError as exc:
            # a half-bound listener must never linger (§2.2)
            print(f"bind failed: {exc.__class__.__name__}", file=sys.stderr)
            await runner.cleanup()
            raise SystemExit(1)
        await asyncio.Event().wait()

    asyncio.run(run())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
