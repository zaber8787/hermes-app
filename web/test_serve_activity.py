#!/usr/bin/env python3
"""WAVE4 thin pass-through suite for GET /api/sessions/{sid}/activity (§3.6).

    ~/.hermes/hermes-agent/venv/bin/python web/test_serve_activity.py

The proxy adds NO activity logic; these tests only pin transparency: auth and
profile headers arrive, HTTP status and JSON body pass through unchanged,
Cache-Control: no-store survives, and no proxy-side state appears (a 503 is
still a 503, never a rewritten idle). (serve.API is repointed at a fake
upstream, same Harness pattern as test_upstream.py.)
"""
import asyncio
import contextlib
import json
import pathlib
import sys

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

KEY = "sk-act"
BEARER = ("Bearer ", KEY)[0] + KEY[1:]
SEEN = []


async def upstream(request):
    SEEN.append({
        "path": request.path_qs,
        "auth": request.headers.get("Authorization", ""),
        "profile": request.headers.get("X-Hermes-Profile", ""),
    })
    kind = request.match_info["sid"]
    if kind == "boom":
        return web.json_response(
            {"error": {"message": "Session activity snapshot unavailable."}},
            status=503, headers={"Cache-Control": "no-store"})
    if kind == "room":
        return web.json_response({"error": {"code": "room_grant_not_allowed"}},
                                 status=403, headers={"Cache-Control": "no-store"})
    return web.json_response(
        {"object": "hermes.session.activity", "schema_version": 1,
         "session_id": kind, "active_runs": [{"run_id": "run_1", "status": "running"}],
         "recent_terminal": [], "overflow": False},
        headers={"Cache-Control": "no-store"})


async def main():
    fake = web.Application()
    fake.router.add_get("/api/sessions/{sid}/activity", upstream)
    runner = web.AppRunner(fake)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", 0).start()
    saved = serve.API
    serve.API = f"http://127.0.0.1:{runner.addresses[0][1]}"
    app = serve.build_app()
    pr = web.AppRunner(app)
    await pr.setup()
    await web.TCPSite(pr, "127.0.0.1", 0).start()
    port = pr.addresses[0][1]
    try:
        async with ClientSession(timeout=ClientTimeout(total=15)) as client:
            url = f"http://127.0.0.1:{port}"
            async with client.get(url + "/api/sessions/s%2F1/activity", headers={
                    "Authorization": "Bearer " + KEY,
                    "X-Hermes-Profile": "alpha"}) as r:
                body = await r.json()
                assert r.status == 200, r.status
                assert body["object"] == "hermes.session.activity", body
                assert r.headers.get("Cache-Control") == "no-store", r.headers
                assert SEEN[-1]["path"] == "/api/sessions/s%2F1/activity", SEEN[-1]
                assert SEEN[-1]["auth"] == "Bearer " + KEY, SEEN[-1]
                assert SEEN[-1]["profile"] == "alpha", SEEN[-1]
            async with client.get(url + "/api/sessions/boom/activity",
                                  headers={"Authorization": BEARER}) as r:
                assert r.status == 503, "proxy must pass 503 through, never rewrite idle"
            async with client.get(url + "/api/sessions/room/activity",
                                  headers={"Authorization": BEARER}) as r:
                assert r.status == 403, r.status
            # no proxy-side state: a second identical GET is just another forward
            async with client.get(url + "/api/sessions/s2/activity",
                                  headers={"Authorization": BEARER}) as r:
                assert r.status == 200 and r.headers.get("Cache-Control") == "no-store"
            assert len(SEEN) == 4, SEEN
    finally:
        with contextlib.suppress(Exception):
            await asyncio.wait_for(pr.cleanup(), 10)
        with contextlib.suppress(Exception):
            await runner.cleanup(force=True)
        serve.API = saved
    print("6/6 passed")


if __name__ == "__main__":
    asyncio.run(main())
