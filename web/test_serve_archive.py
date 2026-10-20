#!/usr/bin/env python3
"""ARTIFACT-PERSIST archive suite (plain asyncio, like test_serve_memories).

    ~/.hermes/hermes-agent/venv/bin/python web/test_serve_archive.py

The gateway's artifacts are single-use with a 5-minute TTL; the proxy mirrors
uploads into HERMES_WEB_HOME/media-archive and serves the archive when the
gateway download misses. Covers: upload tee + receipt passthrough, gateway-
hit download streams untouched, gateway-miss download served from archive
(content-type + filename), traversal-shaped ids rejected, no key 401, cap
413, and GC of stale entries.
"""
import asyncio
import hashlib
import json
import os
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from aiohttp import web  # noqa: E402

import os as _os, tempfile as _tf  # noqa: E402
if not (_os.environ.get("HERMES_ENV_FILE") or "").strip():
    _env_probe = _tf.NamedTemporaryFile(
        mode="w", suffix=".env", delete=False, prefix="serve-import-")
    _env_probe.write("API_SERVER_KEY=\n")
    _env_probe.close()
    _os.environ["HERMES_ENV_FILE"] = _env_probe.name
import serve  # noqa: E402

FAKE_BEARER = "ap-test-key"
AUTH = {"Authorization": f"Bearer {FAKE_BEARER}"}
AID = hashlib.sha256(b"img").hexdigest()[:32]
PNG = bytes.fromhex("89504e470d0a1a0a") + b"pixel" * 8


class FakeGateway:
    """artifacts upload -> 201 receipt; download -> gateway-mode driven."""

    def __init__(self):
        self.gateway_mode = "hit"  # hit | miss
        self.download_body = b"gateway-fresh-bytes"
        self.app = web.Application()
        self.app.router.add_post("/v1/artifacts/upload", self.upload)
        self.app.router.add_get("/v1/artifacts/download/{aid}", self.download)
        self._runner = None

    async def upload(self, request):
        await request.read()
        return web.json_response(
            {"artifact_id": AID, "filename": "截圖 2026-10-20.png",
             "content_type": "image/png", "size": len(PNG)}, status=201)

    async def download(self, request):
        if self.gateway_mode == "hit":
            return web.Response(body=self.download_body,
                                content_type="image/png")
        return web.json_response(
            {"error": {"message": "artifact not found or expired"}}, status=404)

    async def start(self):
        self._runner = web.AppRunner(self.app)
        await self._runner.setup()
        site = web.TCPSite(self._runner, "127.0.0.1", 0)
        await site.start()
        return self._runner.addresses[0][1]

    async def stop(self):
        await self._runner.cleanup()


async def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="serve-archive-"))
    (tmp / ".env").write_text(f"API_SERVER_KEY={FAKE_BEARER}\n", encoding="utf-8")
    gw = FakeGateway()
    gw_port = await gw.start()

    saved = (serve.ENV_FILE, serve.API)
    serve.ENV_FILE = tmp / ".env"
    serve.API = f"http://127.0.0.1:{gw_port}"
    os.environ["HERMES_WEB_HOME"] = str(tmp)
    serve.ARTIFACT_ARCHIVE = tmp / "media-archive"

    app = serve.build_app()
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = runner.addresses[0][1]
    base = f"http://127.0.0.1:{port}"

    from aiohttp import ClientSession
    async with ClientSession() as s:
        # 1. upload: receipt passthrough + archive + sidecar on disk
        async with s.post(base + "/v1/artifacts/upload", data=PNG,
                          headers={**AUTH, "Content-Type": "image/png"}) as r:
            assert r.status == 201, r.status
            receipt = await r.json()
        assert receipt["artifact_id"] == AID
        blob = serve.ARTIFACT_ARCHIVE / AID
        assert blob.read_bytes() == PNG, "archive bytes differ"
        side = json.loads((serve.ARTIFACT_ARCHIVE / (AID + ".json"))
                          .read_text(encoding="utf-8"))
        assert side["content_type"] == "image/png"
        assert side["filename"] == "截圖 2026-10-20.png"

        # 2. gateway-hit download: upstream bytes, untouched
        async with s.get(base + f"/v1/artifacts/download/{AID}",
                         headers=AUTH) as r:
            assert r.status == 200 and await r.read() == b"gateway-fresh-bytes"

        # 3. gateway-miss: archive takes over with the original metadata
        gw.gateway_mode = "miss"
        async with s.get(base + f"/v1/artifacts/download/{AID}",
                         headers=AUTH) as r:
            assert r.status == 200, r.status
            assert await r.read() == PNG
            assert r.headers["Content-Type"] == "image/png"
            assert "2026-10-20" in r.headers["Content-Disposition"], "utf-8 name"

        # 4. unknown id stays 404; malformed ids never touch the filesystem
        async with s.get(base + "/v1/artifacts/download/" + "0" * 32,
                         headers=AUTH) as r:
            assert r.status == 404
        for evil in ("..%2F..%2Fetc%2Fpasswd", "z" * 32, "A" * 32):
            async with s.get(base + f"/v1/artifacts/download/{evil}",
                             headers=AUTH) as r:
                assert r.status in (400, 404), evil

        # 5. auth gate on both new routes
        async with s.post(base + "/v1/artifacts/upload", data=PNG) as r:
            assert r.status == 401
        async with s.get(base + f"/v1/artifacts/download/{AID}") as r:
            assert r.status == 401

        # 6. body cap (lowered for the test only)
        saved_cap = serve.MAX_BODY_BYTES
        serve.MAX_BODY_BYTES = 8
        async with s.post(base + "/v1/artifacts/upload", data=b"x" * 64,
                          headers={**AUTH, "Content-Type": "image/png"}) as r:
            assert r.status == 413, r.status
        serve.MAX_BODY_BYTES = saved_cap
        leftovers = [p.name for p in serve.ARTIFACT_ARCHIVE.iterdir()
                     if p.name.startswith(".tee-")]
        assert not leftovers, f"tee temp left behind: {leftovers}"

        # 7. GC: an entry aged past the cap is gone after the next upload
        old = serve.ARTIFACT_ARCHIVE / ("f" * 32)
        old.write_bytes(b"stale")
        os.utime(old, (0, 0))
        async with s.post(base + "/v1/artifacts/upload", data=PNG,
                          headers={**AUTH, "Content-Type": "image/png"}) as r:
            assert r.status == 201
        assert not old.exists(), "GC left a stale entry"

    await runner.cleanup()
    await gw.stop()
    serve.ENV_FILE, serve.API = saved
    print("test_serve_archive.py: ALL OK")


asyncio.run(main())
