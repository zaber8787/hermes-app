"""A real guard in an executor; the fixture never executes shell commands."""
from __future__ import annotations
import asyncio
import json
import os
from pathlib import Path
import threading
from unittest.mock import patch
from .offline import AUTH, profiles


async def next_event(response, wanted=None, timeout=12):
    name, data = None, []
    async def read():
        nonlocal name, data
        async for raw in response.content:
            line = raw.decode().rstrip("\r\n")
            if line.startswith("event:"):
                name = line[6:].strip()
            elif line.startswith("data:"):
                data.append(line[5:].strip())
            elif not line and data:
                payload = json.loads("\n".join(data))
                event = name or payload.get("type") or payload.get("event")
                name, data = None, []
                if wanted is None or event == wanted or payload.get("type") == wanted:
                    return event, payload
        raise AssertionError(f"SSE ended before {wanted}")
    return await asyncio.wait_for(read(), timeout)


async def case_approval(args, server, check):
    from hermes_state import SessionDB
    from tools import approval, approval_context
    from gateway.session_context import set_session_vars, clear_session_vars
    from gateway.platforms import api_server as api
    from tools.approval_detection import detect_dangerous_command
    command = "rm -rf /tmp/compat-probe-never-executed"
    check(detect_dangerous_command(command)[0], "fixture command triggers real dangerous-command guard")
    outcomes = {}
    agents = []

    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = "fixture", "compat-fixture"
        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False
            self._interrupt_event = threading.Event()
            agents.append(self)
        def interrupt(self, *args, **kwargs):
            self.interrupted = True
            self._interrupt_event.set()
        def run_conversation(self, user_message, **kwargs):
            result = approval.check_dangerous_command(command, env_type="local")
            outcomes[user_message] = result
            if result["approved"]:
                (Path.cwd()/f"sentinel-{user_message}").write_text("approved once")
            return {"final_response":"approved" if result["approved"] else "denied",
                    "messages":[], "interrupted":self.interrupted}

    async with server() as (adapter, client):
        db = SessionDB(Path("approval.db"))
        sid = db.create_session("compat-approval", "api_server")
        adapter._session_db = db
        adapter._max_concurrent_runs = 8
        # Only substitute the expensive external agent factory. All gateway,
        # policy, registry, SSE and HTTP-resolution code remains real.
        with patch.object(adapter, "_create_agent", side_effect=lambda **kw: Agent(**kw)):
            async def start(label, native=False, prefix="", headers=AUTH):
                if native:
                    async with client.post(prefix+"/v1/runs",json={"input":label,"session_id":sid},headers=headers) as r:
                        check(r.status == 202, f"native runs accepted HTTP202, got {r.status}")
                        run_id = (await r.json())["run_id"]
                    response = await client.get(prefix+f"/v1/runs/{run_id}/events",headers=headers)
                else:
                    response = await client.post(prefix+f"/api/sessions/{sid}/chat/stream",json={"message":label},headers=headers)
                check(response.status == 200, "session/runs SSE HTTP200")
                _, event = await next_event(response,"approval.request")
                check(all(k in event for k in ("run_id","request_id","choices","command")), "approval card has run/request/choices/command")
                check(label not in outcomes, "action remains blocked before response")
                run_id = event["run_id"]
                async with client.get(prefix+f"/v1/runs/{run_id}",headers=headers) as r:
                    status = await r.json()
                    check(status["status"] == "waiting_for_approval", "poll status waiting_for_approval")
                return response,event

            async def answer(event, choice, auth=AUTH, prefix=""):
                async with client.post(prefix+f"/v1/runs/{event['run_id']}/approval",json={"choice":choice,"request_id":event["request_id"]},headers=auth) as r:
                    return r.status

            async def finish(response, label):
                await asyncio.wait_for(response.read(), 12)
                response.close()
                for _ in range(100):
                    if label in outcomes: break
                    await asyncio.sleep(.01)
                check(label in outcomes, "worker exits after decision")

            for native in (False, True):
                for choice in ("once","deny"):
                    label=f'{"runs" if native else "session"}-{choice}'
                    response,event=await start(label,native)
                    check(await answer(event,choice,{"Authorization":"Bearer wrong"})==401, "wrong auth cannot resolve approval")
                    check(label not in outcomes, "unauthorized request leaves waiter blocked")
                    check(await answer(event,choice)==200, "approval HTTP200")
                    await finish(response,label)
                    check(outcomes[label]["approved"] == (choice=="once"), "guard obeys once/deny")
                    check((Path.cwd()/f"sentinel-{label}").exists() == (choice=="once"), "only approved action writes sentinel")
            # Two simultaneous turns in one session must retain distinct listener keys.
            first,e1=await start("parallel-a")
            second,e2=await start("parallel-b")
            check(e1["run_id"]!=e2["run_id"], "parallel run IDs distinct")
            check(await answer(e1,"once")==200, "first parallel approval accepted")
            await finish(first,"parallel-a")
            check("parallel-b" not in outcomes, "first approval cannot unblock second run")
            check(await answer(e2,"deny")==200, "second parallel denial accepted")
            await finish(second,"parallel-b")
            response,event=await start("timeout")
            await finish(response,"timeout")
            check(not outcomes["timeout"]["approved"], "timeout fails closed (fixture timeout=3s)")
            response,event=await start("stopped")
            async with client.post(f"/v1/runs/{event['run_id']}/stop",json={},headers=AUTH) as r:
                check(r.status==200,"stop HTTP200")
            await finish(response,"stopped")
            check(not outcomes["stopped"]["approved"], "stop wakes waiter without approving")
            # Shorten only SSE heartbeat in the disposable worker so a dead
            # client is detected promptly; production keepalive is unmodified.
            with patch.object(api,"CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS",.03):
                response,event=await start("disconnected")
                response.close()
                for _ in range(300):
                    if "disconnected" in outcomes: break
                    await asyncio.sleep(.01)
                check("disconnected" in outcomes and not outcomes["disconnected"]["approved"], "disconnect releases pending waiter")
            response,event=await start("shutdown")
            check(adapter.interrupt_active_runs("gateway shutdown") >= 1, "shutdown interrupts active worker")
            await finish(response,"shutdown")
            check(not outcomes["shutdown"]["approved"], "shutdown releases approval waiter")
            with profiles(adapter) as entries:
                for index,(name,headers,root) in enumerate((entries[0],entries[1],entries[0])):
                    other = entries[1] if name == "alpha" else entries[0]
                    prefix = "/p/"+name
                    label = f"profile-{name}-{index}"
                    response,event=await start(label,prefix=prefix,headers=headers)
                    wrong=await answer(event,"once",other[1],"/p/"+other[0])
                    check(wrong in {403,404}, "other profile cannot approve owned run")
                    async with client.post("/p/"+other[0]+f"/v1/runs/{event['run_id']}/stop",json={},headers=other[1]) as r:
                        check(r.status in {403,404}, "other profile cannot stop owned run")
                    check(label not in outcomes, "foreign approve/stop leaves waiter blocked")
                    check(await answer(event,"deny",headers,prefix)==200,"profile owner can deny")
                    await finish(response,label)
                    check(not outcomes[label]["approved"], "A/B/A worker context stays isolated")
            with patch.object(adapter,"_create_agent",side_effect=RuntimeError("fixture construction failure")):
                response=await client.post(f"/api/sessions/{sid}/chat/stream",json={"message":"worker-error"},headers=AUTH)
                await next_event(response,"error")
                await asyncio.wait_for(response.read(),5)
                response.close()
                check(not approval._gateway_notify_cbs, "worker exception unregisters listener")
            await asyncio.sleep(.1)
            check(not approval._gateway_notify_cbs and not approval._gateway_queues, "all listeners and pending queues released")
            check(not adapter._run_approval_sessions, "run approval mappings released")
            check(adapter.active_agent_work_count()==0, "no inflight/admission leak")
        db.close()

    for platform,cron,single in (("api_server","",""),("webhook","",""),("api_server","1",""),("api_server","","1")):
        tokens=set_session_vars(platform=platform,session_key="unattended",cron_session=cron)
        old=os.environ.get("HERMES_SINGLE_QUERY_SESSION")
        os.environ["HERMES_SINGLE_QUERY_SESSION"]=single
        try:
            result=approval.check_dangerous_command(command,env_type="local")
            check(not result["approved"], f"no-listener {platform}/cron={cron}/single={single} remains denied")
        finally:
            clear_session_vars(tokens)
            if old is None: os.environ.pop("HERMES_SINGLE_QUERY_SESSION",None)
            else: os.environ["HERMES_SINGLE_QUERY_SESSION"]=old
    return "PASS","real guard→executor→SSE→POST: session + runs, once/deny/timeout/stop/disconnect/shutdown, parallel and A/B/A profile isolation"
