"""Same-session suspect storm: real delivery/due/HTTP/terminal and historical proofs."""
from __future__ import annotations
import asyncio
import importlib
import json
import os
import threading
import time
from pathlib import Path
from unittest.mock import patch

from .cron_bridge import profile_db
from .selfwake import sw_ref, bridge_store, set_mode
from .wake import wake_ref
from .offline import AUTH, FAKE_BEARER


async def case_wakelatch(args, server, check):
    home = Path(os.environ['HERMES_HOME']).resolve()
    sw, bridge, refs = sw_ref(), bridge_store(), wake_ref()
    store, mod = refs['store'], refs['module']
    db = profile_db()
    calls = []

    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = 'fixture', 'compat-fixture'
        def __init__(self, **kw):
            self.session_id = kw.get('session_id')
            self.interrupted = False
            self._interrupt_event = threading.Event()
        def interrupt(self,*args,**kw):
            self.interrupted = True
            self._interrupt_event.set()
        def run_conversation(self,user_message,**kw):
            calls.append({'session_id':self.session_id,'input':user_message})
            return {'final_response':'fixture read the external report',
                    'messages':[], 'interrupted':self.interrupted}

    async def deliver(sid, execution, body='external worker report'):
        result = await asyncio.to_thread(bridge.deliver, session_id=sid, content=body,
                                         identity={'job_id':'wl-job','execution_id':execution,'name':'fixture'})
        check(result['status']=='delivered', 'fake delivery committed a real provenance row')
        return bridge.delivery_key(home=str(home),job_id='wl-job',execution_id=execution,session_id=sid)

    async with server() as (adapter, client):
        # connect may rediscover/reload the profile plugin: use the current
        # module references, not a pre-connect module reset by discovery.
        sw, bridge, refs = sw_ref(), bridge_store(), wake_ref()
        store, mod = refs['store'], refs['module']
        async with client.get('/v1/capabilities',headers=AUTH) as response:
            before_caps = await response.json()
        background = sw._module_state.get('worker')
        if background:
            background.stop()  # deterministic manual ticks, same real worker code
        port = adapter._site._server.sockets[0].getsockname()[1]
        cfg = json.loads((home/'config.yaml').read_text())
        cfg['gateway']={'api_server':{'enabled':True,'host':'127.0.0.1','port':port,'key':FAKE_BEARER}}
        (home/'config.yaml').write_text(json.dumps(cfg))
        set_mode({'selfwake':True,'selfwake_chain_limit':3,'selfwake_cooldown_seconds':0})
        sid='wl-same-session'
        db.create_session(sid,model='compat-fixture',source='api_server')
        old_key=await deliver(sid,'historical')
        admitted=await asyncio.to_thread(store.admit,home,session_id=sid,resolved=sid,
                                         keys=[old_key],db=db,owner='self:wl-old')
        check(admitted['status']=='admitted','old batch admitted through real ledger')
        old=admitted['batch_id']
        check(store.gate_dispatch(home,batch_id=old,resolved=sid,input_text=mod.CANONICAL_INPUT) is None,
              'old batch passed real dispatch CAS')
        store.report(home,batch_id=old,resolved=sid,state='accepted',run_id='wl-old-run')
        ledger=store.open_ledger(home)
        ledger.execute('UPDATE wake_batches SET created_at=? WHERE batch_id=?',(time.time()-7200,old))
        ledger.commit()
        intents=sw._bridge(home)
        intents.execute("UPDATE selfwake_intents SET state='done',detail='uncertain-consumed',batch_id=?"
                        ' WHERE delivery_key=?',(old,old_key))
        intents.commit()
        adapter._set_run_status('wl-old-run','completed',session_id=sid,created_at=time.time()-7200)
        from aiohttp.test_utils import make_mocked_request
        adapter._run_owners['wl-old-run'] = adapter._run_idempotency_scope(
            make_mocked_request('GET','/v1/runs/wl-old-run',headers=AUTH))
        async with client.get('/v1/runs/wl-old-run',headers=AUTH) as response:
            snapshot = await response.json()
            check(response.status == 200 and snapshot['status']=='completed',
                  'profile-owned terminal fixture is available through real GET')
        # Real core mirror-shaped row: plain user, not compat provenance.
        db.append_message(sid,'user','[Cron delivery: fixture]\nmirrored report')
        new_key=await deliver(sid,'fresh')
        worker=sw.SelfWakeWorker(home)
        check(sw.endpoint(home)[0] is not None,'isolated profile dispatch endpoint is enabled')
        check([r['delivery_key'] for r in worker._due(time.time())]==[new_key],
              'done zombie is not due; real fresh report is selected')
        with patch.object(adapter,'_create_agent',side_effect=lambda **kw:Agent(**kw)):
            await asyncio.wait_for(worker.tick(),20)
            diagnostic = {'old_state':store.receipt(home,batch_id=old,resolved=sid)['receipt']['state'],
                          'intent': [list(r) for r in intents.execute(
                              'SELECT state,detail FROM selfwake_intents WHERE delivery_key=?',(new_key,))],
                          'audit':[list(r) for r in ledger.execute(
                              'SELECT phase,reason FROM selfwake_audit ORDER BY seq DESC LIMIT 3')]}
            check(len(calls)==1,'same-session zombie and mirror do not suppress real POST ignition: '+json.dumps(diagnostic))
            check(calls[0]['input']==mod.CANONICAL_INPUT,'POST uses unchanged canonical input')
            terminal=list(ledger.execute("SELECT batch_id,run_id FROM selfwake_audit"
                                         " WHERE trigger='self' AND phase='terminal' AND run_id IS NOT NULL"))
            check(len(terminal)==1,'true self terminal audit carries run_id')
            check(True,'E2E terminal evidence: '+json.dumps(
                {'trigger':'self','phase':'terminal','batch_id':terminal[0]['batch_id'],
                 'run_id':terminal[0]['run_id']}))
            check(store.receipt(home,batch_id=old,resolved=sid)['receipt']['state']=='terminal',
                  'run proof closes old accepted batch without replaying it')
            check(intents.execute('SELECT state FROM selfwake_intents WHERE delivery_key=?',(new_key,))
                  .fetchone()[0]=='done','fresh intent settled only after ledger terminal')
            worker._next_reconcile=0
            await worker.tick()
            check(len(calls)==1,'repeated sweep never replays consumed reports')
        # Unknown/live run and reserved+done keep claims; no blanket cleanup.
        repair=importlib.import_module(sw.__package__+'.wake_reconcile')
        for index,state in enumerate(('accepted','reserved')):
            target='wl-unknown-'+str(index)
            db.create_session(target,model='compat-fixture',source='api_server')
            key=await deliver(target,'unknown-'+str(index))
            result=store.admit(home,session_id=target,resolved=target,keys=[key],db=db,owner='self:unknown')
            bid=result['batch_id']
            if state=='accepted':
                store.gate_dispatch(home,batch_id=bid,resolved=target,input_text=mod.CANONICAL_INPUT)
                store.report(home,batch_id=bid,resolved=target,state='accepted',run_id='missing-run')
            intents.execute("UPDATE selfwake_intents SET state='done',batch_id=?,updated_at=?"
                            ' WHERE delivery_key=?',(bid,time.time(),key))
            intents.commit()
            unresolved=repair.reconcile_batches(home,lambda b:None,dry_run=False,batch_ids=[bid])
            check(unresolved['rows'][0]['result']=='unresolved','unknown evidence never authorizes automatic cleanup')
            conserved=store.receipt(home,batch_id=bid,resolved=target)['receipt']['rows']
            planned=repair.reconcile_batches(home,lambda b:None,batch_ids=[bid],allow_done_intents=True)
            check(planned['rows'][0]['result']=='planned','explicit done-intent dry-run is reviewable')
            result=repair.reconcile_batches(home,lambda b:None,dry_run=False,batch_ids=[bid],allow_done_intents=True)
            check(result['rows'][0]['result']=='settled','authorized done-intent bookkeeping settles once')
            receipt=store.receipt(home,batch_id=bid,resolved=target)['receipt']
            check(receipt['state']=='uncertain-consumed' and receipt['rows']==conserved,
                  'done-only settlement retains consumption and does not invent completed run')
        check(before_caps['features']['auto_wake']['selfwake']['liveness']['state']=='armed',
              'capability exposes the current selfwake manifest liveness')
        check(all(c['session_id']==sid for c in calls),'no unknown or reserved zombie launched another run')
        # A transient settlement conflict must be retried as observation,
        # never as another POST and never as a permanent accepted latch.
        target='wl-conflict-recovery'
        db.create_session(target,model='compat-fixture',source='api_server')
        key=await deliver(target,'conflict-recovery')
        result=store.admit(home,session_id=target,resolved=target,keys=[key],db=db,owner='self:conflict')
        bid=result['batch_id']
        store.gate_dispatch(home,batch_id=bid,resolved=target,input_text=mod.CANONICAL_INPUT)
        store.report(home,batch_id=bid,resolved=target,state='accepted',run_id='wl-conflict-run')
        intents.execute("UPDATE selfwake_intents SET state='watching',batch_id=?,"
                        "detail='ledger-settlement-conflict',next_attempt_at=0,updated_at=?"
                        ' WHERE delivery_key=?',(bid,time.time(),key))
        intents.commit()
        adapter._set_run_status('wl-conflict-run','completed',session_id=target)
        adapter._run_owners['wl-conflict-run']=adapter._run_idempotency_scope(
            make_mocked_request('GET','/v1/runs/wl-conflict-run',headers=AUTH))
        with patch.object(adapter,'_create_agent',side_effect=lambda **kw:Agent(**kw)):
            await asyncio.wait_for(sw.SelfWakeWorker(home).tick(),20)
        check(store.receipt(home,batch_id=bid,resolved=target)['receipt']['state']=='terminal',
              'accepted settlement conflict converges through real status observation')
        check(intents.execute('SELECT state FROM selfwake_intents WHERE delivery_key=?',(key,))
              .fetchone()[0]=='done','observed recovery closes intent after ledger')
        check(len(calls)==1,'conflict recovery never issues another model POST')
