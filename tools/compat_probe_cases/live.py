"""Explicit operator-invoked probes; no configuration/install/restart actions."""
from __future__ import annotations
import asyncio
import base64
import json
import shlex
from pathlib import Path
import tempfile
import time
import uuid
from .offline import CAP, MIMES, PNG, upload, DETAILS
from .approval import next_event


def token_from(path):
    lines = path.read_text().splitlines()
    values = [line.split("=",1)[1].strip().strip('"').strip("'")
              for line in lines if line.startswith("API_SERVER_KEY=")]
    if len(values)!=1 or not values[0]:
        raise ValueError("token file must contain exactly one API_SERVER_KEY")
    return values[0]


class FixtureError(RuntimeError):
    """A live model/configuration did not produce the requested fixture."""


def demand(ok, reason):
    if not ok:
        raise AssertionError(reason)


async def run(args):
    from aiohttp import ClientSession, ClientTimeout
    if not args.base_url or not args.token_file:
        raise ValueError("live requires --base-url and --token-file")
    from urllib.parse import urlsplit
    parsed=urlsplit(args.base_url)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("base URL must not contain credentials/query/fragment")
    auth={"Authorization":"Bearer "+token_from(args.token_file)}
    root=args.fixture_dir
    if root is not None:
        root.mkdir(parents=True,exist_ok=True)
    results=[]
    selected=[args.only] if args.only else ["upload","limits","media","history","approval","skills"]
    async with ClientSession(base_url=args.base_url.rstrip("/"), timeout=ClientTimeout(total=900)) as client:
        for case in selected:
            start=time.monotonic()
            entry={"id":case,"status":"PASS","repair_file":"compat/compat.py"}
            try:
                if case in {"history","approval"} and not args.allow_test_agent_turns:
                    entry.update(status="NOT_RUN",detail="requires --allow-test-agent-turns")
                elif case in {"media","history","approval"} and root is None:
                    entry.update(status="NOT_RUN",detail="requires --fixture-dir visible on the gateway host")
                elif case=="upload":
                    await upload(client,2<<20,delay=.01,auth=auth)
                    await upload(client,8192,chunked=False,auth=auth)
                elif case=="limits":
                    await upload(client,12<<20,chunked=False,auth=auth)
                    for mime in MIMES:
                        await upload(client,1024,mime=mime,auth=auth)
                        await asyncio.sleep(7)  # three artifact operations/sample, <=30/min
                    await upload(client,1024,mime="application/x-compat-reject",expected=415,auth=auth)
                    if args.full_size:
                        for chunked in (False,True):
                            await upload(client,CAP,chunked=chunked,auth=auth)
                            await upload(client,CAP+1,chunked=chunked,expected=413,auth=auth)
                            await asyncio.sleep(10)
                    else:
                        entry.update(status="NOT_RUN",detail="full-size boundary not requested")
                elif case=="media":
                    with tempfile.TemporaryDirectory(prefix="media-",dir=root) as temp:
                        path=Path(temp)/"圖片 # compat.png"
                        path.write_bytes(PNG)
                        async with client.get("/v1/media/download",params={"path":str(path.resolve())},headers=auth) as r:
                            demand(r.status==200 and await r.read()==PNG,"media HTTP/hash mismatch; fixture must be on gateway host")
                            from urllib.parse import unquote
                            demand(unquote(r.headers.get("Content-Disposition","").split("''")[-1])==path.name,"RFC5987 mismatch")
                        async with client.get("/v1/media/download",params={"path":str(path.resolve())},headers={**auth,"Range":"bytes=0-3"}) as r:
                            demand(r.status==206 and await r.read()==PNG[:4],"Range mismatch")
                        with path.open("wb") as f: f.truncate(CAP+1)
                        async with client.get("/v1/media/download",params={"path":str(path.resolve())},headers=auth) as r:
                            demand(r.status==413,"oversize media must return413")
                        async with client.get("/v1/capabilities",headers=auth) as r:
                            data=await r.json()
                            demand(data.get("endpoints",{}).get("media_download")=={"method":"GET","path":"/v1/media/download"},"media capability missing")
                elif case=="skills":
                    async with client.get("/v1/skills",headers=auth) as r:
                        data=await r.json()
                        demand(r.status==200 and data.get("object")=="list" and isinstance(data.get("data"),list),"skills must return200 JSON list")
                        demand(all(isinstance(s.get("name"),str) for s in data["data"]),"skill names malformed")
                else:
                    with tempfile.TemporaryDirectory(prefix=case+"-",dir=root) as temp:
                        await agent_case(case,client,auth,Path(temp))
                entry.setdefault("detail","HTTP assertions passed; Flutter UI not tested")
            except AssertionError as exc:
                entry.update(status="FAIL",detail=str(exc))
            except Exception as exc:
                # Do not echo arbitrary response bodies, URLs or exception messages.
                entry.update(status="ERROR",detail=type(exc).__name__)
            entry["seconds"]=round(time.monotonic()-start,2)
            print(f'{entry["status"]:7} {case}: {entry["detail"]}',flush=True)
            results.append(entry)
    return {"schema_version":1,"mode":"live","source":"running-gateway","plugin_version":"unverified",
            "agent_revision":"unverified","base_url":args.base_url,"results":results}


async def agent_case(case,client,auth,root):
    async with client.post("/api/sessions",json={"title":"compat-probe-"+uuid.uuid4().hex},headers=auth) as r:
        data=await r.json()
        demand(r.status==201,"test session creation failed")
        sid=(data.get("session") or data).get("id")
        demand(bool(sid),"session response missing id")
    try:
        if case=="history":
            path=root/"fixture.png"
            path.write_bytes(PNG)
            prompt=f"Reply with exactly this media tag, without using tools: MEDIA:{path.resolve()}"
            async with client.post(f"/api/sessions/{sid}/chat",json={"message":prompt},headers=auth) as r:
                demand(r.status==200,"history fixture agent turn failed")
                await r.read()
            for _ in range(2):
                async with client.get(f"/api/sessions/{sid}/messages",headers=auth) as r:
                    data=await r.json()
                    demand(r.status==200,"history GET failed")
                    images=[m.get("content","") for m in data["data"] if m.get("role")=="assistant" and isinstance(m.get("content"),str) and "data:image/png;base64," in m["content"]]
                    if not images:
                        raise FixtureError("agent did not produce a resolvable MEDIA fixture")
                    encoded=images[-1].split("base64,",1)[1].split(")",1)[0]
                    demand(base64.b64decode(encoded)==PNG,"history image hash mismatch")
        else:
            scenarios = ((False,"once"),(False,"deny"),(True,"once"),(True,"deny"),
                         (False,"stop"),(False,"timeout"),(False,"disconnect"))
            for native,choice in scenarios:
                target=root/(("runs-" if native else "session-")+choice)
                target.mkdir()
                prompt=(f"Use the terminal tool once to run exactly this command:\nrm -rf -- {shlex.quote(str(target.resolve()))}\n\n"
                        "This is an empty directory created by the compatibility probe. "
                        "Wait for human approval. If denied, interrupted or timed out, stop; "
                        "do not retry or use another tool.")
                run_id = None
                if native:
                    async with client.post("/v1/runs",json={"input":prompt,"session_id":sid},headers=auth) as r:
                        demand(r.status==202,"native run creation failed")
                        run_id=(await r.json())["run_id"]
                    response=await client.get(f"/v1/runs/{run_id}/events",headers={**auth,"Accept":"text/event-stream"})
                else:
                    response=await client.post(f"/api/sessions/{sid}/chat/stream",json={"message":prompt},headers={**auth,"Accept":"text/event-stream"})
                try:
                    demand(response.status==200,"approval SSE failed")
                    try:
                        if not native:
                            _,started=await next_event(response,"run.started",timeout=120)
                            run_id=started["run_id"]
                        _,card=await next_event(response,"approval.request",timeout=120)
                    except (AssertionError,asyncio.TimeoutError) as exc:
                        raise FixtureError("model/policy did not produce an approval card") from exc
                    demand(target.exists(),"action ran before approval")
                    async with client.get(f"/v1/runs/{run_id}",headers=auth) as r:
                        demand(r.status==200 and (await r.json())["status"]=="waiting_for_approval","approval status missing")
                    if choice in {"once","deny"}:
                        async with client.post(f"/v1/runs/{run_id}/approval",json={"choice":choice,"request_id":card["request_id"]},headers=auth) as r:
                            demand(r.status==200,"approval response failed")
                    elif choice=="stop":
                        async with client.post(f"/v1/runs/{run_id}/stop",json={},headers=auth) as r:
                            demand(r.status==200,"stop failed")
                    if choice=="disconnect":
                        response.close()
                        # The proxy intentionally drains detached SSE; either
                        # disconnect cancellation or normal timeout may settle it.
                        deadline=time.monotonic()+600
                        while True:
                            async with client.get(f"/v1/runs/{run_id}",headers=auth) as r:
                                data=await r.json()
                            if data.get("status") in {"completed","failed","cancelled","interrupted"}:
                                break
                            if time.monotonic()>=deadline:
                                raise FixtureError("detached run did not settle within600s")
                            await asyncio.sleep(1)
                    else:
                        await asyncio.wait_for(response.read(),600 if choice=="timeout" else 180)
                    demand(target.exists()==(choice!="once"),"approval/cancellation did not control action")
                finally:
                    if run_id is not None:
                        async with client.post(f"/v1/runs/{run_id}/stop",json={},headers=auth) as stop:
                            await stop.read()
                    response.close()
    finally:
        # Only the session created above; never enumerate/delete user sessions.
        async with client.delete(f"/api/sessions/{sid}",headers=auth) as r:
            await r.read()
