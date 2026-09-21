"""Only imported by clean-HEAD workers with disposable HOME and HERMES_HOME."""
from __future__ import annotations
import asyncio
import base64
from contextlib import asynccontextmanager, contextmanager
import hashlib
import inspect
import json
import logging
import os
from pathlib import Path
import resource
import socket
import time
import traceback
from unittest.mock import patch

CAP = 524288000
KEY = "compat-probe-only-0123456789abcdef0123456789"
AUTH = {"Authorization": "Bearer " + KEY}
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7n8AAAAASUVORK5CYII=")
MIMES = ("application/octet-stream", "application/zip", "application/x-zip-compressed",
         "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
         "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
         "application/vnd.openxmlformats-officedocument.presentationml.presentation")
DETAILS = []


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    DETAILS.append(message)


def guard_network():
    old = socket.socket.connect
    def connect(sock, address):
        if isinstance(address, tuple) and address[0] not in {"127.0.0.1", "::1", "localhost"}:
            raise RuntimeError("offline probe blocked non-loopback connection")
        return old(sock, address)
    socket.socket.connect = connect


def load_plugins():
    from hermes_cli.plugins import get_plugin_manager, discover_plugins
    discover_plugins()
    return get_plugin_manager()


@asynccontextmanager
async def server():
    from aiohttp import ClientSession, ClientTimeout
    from gateway.config import PlatformConfig
    from gateway.platforms.api_server import APIServerAdapter
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": KEY, "host": "127.0.0.1", "port": 0,
                                                                   "model_name": "compat-fixture"}))
    # Rate limit is independent from byte integrity; preserve production defaults
    # except in this disposable fixture, whose many negative cases exceed 30/min.
    from gateway.browser_control_artifacts import ArtifactRateLimiter
    adapter._browser_control_artifact_limiter = ArtifactRateLimiter(max_requests=1000)
    check(await adapter.connect(), "real adapter.connect succeeds")
    port = adapter._site._server.sockets[0].getsockname()[1]
    async with ClientSession(base_url=f"http://127.0.0.1:{port}", timeout=ClientTimeout(total=180)) as client:
        try:
            yield adapter, client
        finally:
            await adapter.disconnect()


async def upload(client, size, *, chunked=True, mime="application/octet-stream", expected=201, delay=0, download=True, auth=AUTH, prefix=""):
    block = bytes(range(256))*256
    digest = hashlib.sha256()
    async def body():
        for offset in range(0, size, len(block)):
            part = block[:min(len(block), size-offset)]
            digest.update(part)
            yield part
            if delay:
                await asyncio.sleep(delay)
    headers = {**auth, "Content-Type": mime, "X-Artifact-Filename": "compat.bin"}
    if not chunked:
        headers["Content-Length"] = str(size)
    async with client.post(prefix+"/v1/artifacts/upload", data=body(), headers=headers) as response:
        payload = await response.json()
        check(response.status == expected, f"upload {size} chunked={chunked} HTTP {expected}, got {response.status}")
    if expected != 201:
        return payload
    check(payload["size_bytes"] == size, f"receipt bytes={size}, actual={payload['size_bytes']}")
    check(payload["sha256"] == digest.hexdigest(), "receipt SHA256 matches complete body")
    if download:
        path = payload.get("download_path") or f"/v1/artifacts/download/{payload['artifact_id']}"
        result = hashlib.sha256()
        count = 0
        async with client.get(prefix+path, headers=auth) as response:
            check(response.status == 200, "artifact one-shot download HTTP200")
            async for chunk in response.content.iter_chunked(1 << 20):
                count += len(chunk)
                result.update(chunk)
        check(count == size and result.hexdigest() == digest.hexdigest(), "download bytes/SHA256 match")
        async with client.get(prefix+path, headers=auth) as response:
            check(response.status == 404, "second download HTTP404")
    return payload


async def case_upload(args):
    async with server() as (adapter, client):
        await upload(client, 2 << 20, delay=.01)
        await upload(client, 8192, chunked=False)
        await upload(client, 0, expected=400)
        async with client.post("/v1/artifacts/upload", data=b"abc", headers={**AUTH, "Content-Type": "text/plain"}) as r:
            check(r.status == 400, "filename required")
        async with client.post("/v1/artifacts/upload", data=b"abc") as r:
            check(r.status == 401, "upload unauthenticated rejected")
        # Inject explicit small store to test cap+1 without sharing plugin's CAP.
        from gateway.browser_control_artifacts import ArtifactStore
        adapter._inject_browser_control_artifacts(ArtifactStore(Path("small-artifacts"), max_bytes=100))
        await upload(client, 101, expected=413)


async def case_limits(args):
    from gateway.browser_control_artifacts import ArtifactStore
    store = ArtifactStore(Path("default-artifacts"))
    check(store.max_bytes == CAP, "captured constructor default is 500MiB")
    check(ArtifactStore(Path("small"), max_bytes=99).max_bytes == 99, "explicit cap preserved")
    async with server() as (adapter, client):
        check(adapter._app._client_max_size == CAP, "connect reads patched request cap")
        check(adapter._artifact_store_for("default").max_bytes == CAP, "API facade imported cap updated")
        await upload(client, 12 << 20, chunked=False)
        for mime in MIMES:
            await upload(client, 1024, mime=mime)
        await upload(client, 1024, mime="application/x-compat-reject", expected=415)
        with profiles(adapter) as entries:
            for name,headers,root in (entries[0],entries[1],entries[0]):
                await upload(client,1024,auth=headers,prefix="/p/"+name)
                check(adapter._browser_control_artifacts[name]._root.is_relative_to(root), "A/B/A artifacts stay in profile root")
        if not args.full_size:
            return "NOT_RUN", "12MiB/MIME passed; full-size boundary not requested"
        for chunked in (False, True):
            await upload(client, CAP, chunked=chunked)
            await upload(client, CAP+1, chunked=chunked, expected=413)
    return "PASS", "500MiB accepted, +1 rejected (fixed/chunked); all MIME/default bindings passed"


async def case_media(args):
    root = Path.cwd()/"fixtures"
    root.mkdir()
    path = root/"圖片 # one.png"
    path.write_bytes(PNG)
    large = root/"large.bin"
    with large.open("wb") as f:
        f.truncate(CAP+1)
    secret = Path(os.environ["HERMES_HOME"])/".env"
    secret.write_text("FAKE_PROBE_SECRET=not-real\n")
    link = root/"link.png"
    link.symlink_to(secret)
    async with server() as (adapter, client):
        check(sum(m == "GET" and p == "/v1/media/download" for m,p,_ in adapter._http_route_table()) == 1,
              "one media route")
        async with client.get("/v1/capabilities", headers=AUTH) as r:
            cap = await r.json()
            check(cap["endpoints"]["media_download"] == {"method": "GET", "path": "/v1/media/download"}, "media capability matches route")
        async with client.get("/v1/media/download", params={"path": str(path)}, headers=AUTH) as r:
            check(r.status == 200 and await r.read() == PNG, "Unicode media contents")
            from urllib.parse import unquote
            check(unquote(r.headers["Content-Disposition"].split("''",1)[1]) == path.name, "RFC5987 Unicode filename")
        async with client.get("/v1/media/download", params={"path": str(path)}, headers={**AUTH,"Range":"bytes=0-3"}) as r:
            check(r.status == 206 and await r.read() == PNG[:4], "media Range206")
        for bad in ("relative.png", str(secret), str(link), str(root/"missing")):
            async with client.get("/v1/media/download", params={"path":bad}, headers=AUTH) as r:
                check(r.status == 400, "unsafe/missing path rejected")
        async with client.get("/v1/media/download", params={"path":str(large)}, headers={**AUTH,"Range":"bytes=0-3"}) as r:
            check(r.status == 413, "oversize media rejected before Range")
        async with client.get("/v1/media/download", params={"path":str(path)}) as r:
            check(r.status == 401, "media bad/missing bearer rejected")
        with patch.object(adapter,"_api_key", ""):
            async with client.get("/v1/media/download",params={"path":str(path)}) as r:
                check(r.status==403,"media refuses missing configured API key")
        os.environ["HERMES_MEDIA_DELIVERY_STRICT"] = "1"
        os.utime(path, (1,1))
        async with client.get("/v1/media/download", params={"path":str(path)}, headers=AUTH) as r:
            check(r.status == 400, "strict mode rejects old outside-root file")
        os.environ["HERMES_MEDIA_ALLOW_DIRS"] = str(root)
        async with client.get("/v1/media/download", params={"path":str(path)}, headers=AUTH) as r:
            check(r.status == 200, "strict mode explicit operator root accepted")

        with profiles(adapter) as entries:
            for name,headers,root in (entries[0],entries[1],entries[0]):
                own=root/"output/image.png"
                own.write_bytes(PNG)
                other=entries[1] if name=="alpha" else entries[0]
                foreign=other[2]/"output/foreign.png"
                foreign.write_bytes(PNG)
                async with client.get(f"/p/{name}/v1/media/download",params={"path":str(own)},headers=headers) as r:
                    check(r.status==200 and await r.read()==PNG, "profile mirror uses own media allow root A/B/A")
                async with client.get(f"/p/{name}/v1/media/download",params={"path":str(foreign)},headers=headers) as r:
                    check(r.status==400, "profile mirror rejects foreign non-allowlisted root")


async def case_history(args):
    from hermes_state import SessionDB
    from gateway.platforms import api_server as api
    image = Path.cwd()/"history.png"
    image.write_bytes(PNG)
    db = SessionDB(Path("history.db"))
    sid = db.create_session("compat-history", "api_server")
    text = f"A picture MEDIA:{image}"
    db.append_message(sid, "assistant", text)
    async with server() as (adapter, client):
        adapter._session_db = db
        for _ in range(2):
            async with client.get(f"/api/sessions/{sid}/messages", headers=AUTH) as r:
                result = await r.json()
                check(r.status == 200, "history HTTP200")
                content = result["data"][0]["content"]
                encoded = content.split("base64,",1)[1].split(")",1)[0]
                check(base64.b64decode(encoded) == PNG, "history/reload data URL roundtrip")
        check(db.get_messages(sid)[0]["content"] == text, "stored history unmodified")
        for content in (None, [], [{"type":"text","text":"hello"}]):
            row={"role":"assistant","content":content}
            check(adapter._message_response(row) == api.APIServerAdapter._message_response(row), "static/instance non-string projection agrees")
        with patch.object(api, "_resolve_media_to_data_urls", side_effect=RuntimeError("fixture")):
            check(adapter._message_response({"content":text})["content"] == text, "resolver exception preserves content")
        huge = Path.cwd()/"huge.png"
        with huge.open("wb") as f: f.truncate((5<<20)+1)
        for content in (f"MEDIA:{huge}", "MEDIA:/missing.png", "plain text"):
            check(adapter._message_response({"content":content})["content"] == content, "oversize/missing/plain preserved")
    db.close()


async def case_skills(args):
    from tools import skills_tool
    root = Path(os.environ["HERMES_HOME"])/"skills/compat-fixture"
    root.mkdir(parents=True)
    (root/"SKILL.md").write_text("---\nname: compat-fixture\ndescription: A probe fixture.\n---\n# Fixture\n")
    async with server() as (_,client):
        async with client.get("/v1/skills", headers=AUTH) as r:
            data = await r.json()
            check(r.status == 200 and data["object"] == "list", "skills HTTP200 JSON list")
            check(any(s["name"] == "compat-fixture" for s in data["data"]), "fixture skill listed")
    check(skills_tool._find_all_skills(skip_disabled=False) ==
          skills_tool._find_all_skills(skip_disabled=False, include_editorial=True), "old/new skill signatures agree")


async def case_control(args):
    async with server() as (_, client):
        # text/plain is accepted by pristine upstream; do not let missing MIME
        # support hide the short read regression.
        async def dribble():
            for _ in range(32):
                yield b"a"*65536
                await asyncio.sleep(.01)
        async with client.post("/v1/artifacts/upload", data=dribble(), headers={**AUTH,"Content-Type":"text/plain","X-Artifact-Filename":"control.txt"}) as r:
            result=await r.json()
            check(r.status == 201 and result["size_bytes"] < 2<<20,
                  f"clean control reproduces truncation: {result.get('size_bytes')} < 2097152")
        async with client.get("/v1/skills",headers=AUTH) as r:
            check(r.status == 500, "clean control reproduces skills HTTP500")
        async with client.get("/api/sessions/whatever/activity", headers=AUTH) as r:
            check(r.status == 404, "clean control: activity endpoint does not exist (404)")
        async with client.get("/v1/capabilities", headers=AUTH) as r:
            cap = await r.json()
            check("session_activity" not in cap.get("endpoints", {}), "clean control: no session_activity capability")


async def case_lifecycle(args):
    from gateway.platforms import api_server as api, api_server_runs as runs
    from tools import approval, approval_context
    from hermes_cli.plugins import PluginContext
    manager = load_plugins()
    loaded = next(p for p in manager._plugins.values() if p.manifest.name == "hermes-app-compat")
    module = loaded.module
    state = getattr(api,"_hermes_app_compat_state_v1")
    current = api.APIServerAdapter._handle_artifact_upload
    module.register(PluginContext(loaded.manifest,manager))
    module.register(PluginContext(loaded.manifest,manager))
    check(api.APIServerAdapter._handle_artifact_upload is current, "repeated register does not stack")
    manager.unload()
    check(api.MAX_REQUEST_BYTES == 10000000, "unload restores request constant")
    check(api.APIServerAdapter._handle_artifact_upload is not current, "unload restores method")
    check(not hasattr(api.APIServerAdapter,"_handle_media_download"), "unload removes added media method")
    check(not hasattr(api.APIServerAdapter,"_handle_session_activity"), "unload removes added activity method")
    from gateway.browser_control_artifacts import ArtifactStore
    check(ArtifactStore(Path("restored")).max_bytes == 10 * 1024 * 1024, "unload restores captured defaults")
    original = runs._handle_stop_run
    del runs._handle_stop_run
    original_predicate = approval_context._is_unattended_platform_approval_context
    module.register(PluginContext(loaded.manifest,manager))
    check(state["manifest"]["approval"]["status"] == "skipped_incompatible", "missing target makes approval red")
    check(state["manifest"]["activity"]["status"] == "skipped_incompatible",
          "approval incompatibility fail-closes activity (no partial capability)")
    check(approval_context._is_unattended_platform_approval_context is original_predicate and
          approval._is_unattended_platform_approval_context is original_predicate, "approval transaction restores both policy bindings")
    check(all(state["manifest"][u]["status"] == "applied" for u in ("upload","limits","media","history","skills")), "other five groups survive approval incompatibility")
    runs._handle_stop_run = original
    manager.unload()
    module.register(PluginContext(loaded.manifest,manager))
    check(all(state["manifest"][u]["status"] == "applied" for u in ("approval","activity")), "restored target re-applies approval and activity")
    # A second loader namespace must share ownership without stacking patches.
    import importlib.util
    from types import SimpleNamespace
    package = Path(module.__file__).parent
    spec = importlib.util.spec_from_file_location("compat_second_profile", package/"__init__.py",
                                                  submodule_search_locations=[str(package)])
    second = importlib.util.module_from_spec(spec)
    import sys
    sys.modules[spec.name] = second
    spec.loader.exec_module(second)
    callbacks = []
    second.register(SimpleNamespace(_manager=object(), on_unload=callbacks.append))
    shared_method = api.APIServerAdapter._handle_artifact_upload
    manager.unload()
    check(api.APIServerAdapter._handle_artifact_upload is shared_method, "first manager unload retains second manager ownership")
    for callback in reversed(callbacks): callback()
    check(api.MAX_REQUEST_BYTES == 10000000, "last manager unload restores globals")
    # Fail mid-commit, after a binding was changed, to test actual rollback.
    compat_module = __import__(module.__name__+".compat",fromlist=["Transaction"])
    original_set = compat_module.Transaction.set
    def failed_set(tx, target, name, value, **kw):
        original_set(tx,target,name,value,**kw)
        if target is approval and name == "_is_unattended_platform_approval_context":
            raise RuntimeError("injected post-binding failure")
    before = approval_context._is_unattended_platform_approval_context
    with patch.object(compat_module.Transaction,"set",failed_set):
        module.register(PluginContext(loaded.manifest,manager))
    check(state["manifest"]["approval"]["status"] == "skipped_incompatible", "mid-commit failure is red")
    check(approval_context._is_unattended_platform_approval_context is before and
          approval._is_unattended_platform_approval_context is before, "mid-commit failure rolls back installed policy bindings")
    manager.unload()
    module.register(PluginContext(loaded.manifest,manager))
    third_party = lambda self, request: None
    api.APIServerAdapter._handle_artifact_upload = third_party
    manager.unload()
    check(api.APIServerAdapter._handle_artifact_upload is third_party, "unload preserves third-party replacement")


async def run(args):
    logging.basicConfig(level=logging.ERROR)
    guard_network()
    try:
        manager = load_plugins()
        from gateway.platforms import api_server as api
        manifest = json.loads(json.dumps(getattr(api, "_hermes_app_compat_state_v1", {}).get("manifest", {})))
        if args.worker != "control":
            check(len(manifest)==7 and all(v["status"]=="applied" for v in manifest.values()), f"seven hook groups installed: {manifest}")
        if args.worker == "approval":
            from .approval import case_approval
            outcome = await case_approval(args, server, check)
        elif args.worker == "activity":
            from .activity import case_activity
            outcome = await case_activity(args, server, check)
        else:
            outcome = await globals()["case_"+args.worker](args)
        status, detail = outcome or ("PASS", f"{len(DETAILS)} assertions")
        return {"id":args.worker,"status":status,"detail":detail,"assertions":DETAILS,
                "manifest":manifest,"peak_rss_kib":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
    except Exception as exc:
        return {"id":args.worker,"status":"FAIL" if isinstance(exc,AssertionError) else "ERROR",
                "detail":str(exc),"diagnostic":traceback.format_exc(),"assertions":DETAILS}


# Real named-profile homes/auth/scope; no policy or owner-check substitution.
@contextmanager
def profiles(adapter):
    from gateway.config import GatewayConfig
    from agent import secret_scope
    from types import SimpleNamespace
    home = Path(os.environ["HERMES_HOME"])
    config = json.loads((home/"config.yaml").read_text())
    entries = []
    for name in ("alpha", "beta"):
        root = home/"profiles"/name
        root.mkdir(parents=True, exist_ok=True)
        key = "compat-"+name+"-0123456789abcdef0123456789"
        (root/".env").write_text("API_SERVER_KEY="+key+"\n")
        cfg = {**config, "plugins":{"enabled":[]},
               "gateway":{"strict":True,"trust_recent_files":False,
                          "media_delivery_allow_dirs":[str(root/"output")]}}
        (root/"config.yaml").write_text(json.dumps(cfg))
        (root/"output").mkdir(exist_ok=True)
        entries.append((name,{"Authorization":"Bearer "+key},root))
    old = adapter.gateway_runner
    adapter.gateway_runner = SimpleNamespace(config=GatewayConfig(multiplex_profiles=True))
    secret_scope.set_multiplex_active(True)
    try:
        yield entries
    finally:
        secret_scope.set_multiplex_active(False)
        adapter.gateway_runner = old
