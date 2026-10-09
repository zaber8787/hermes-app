"""Synthetic stream boundary, real ledger and intent settlement."""
import asyncio
import json
import pathlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from compat import auto_wake_store as store, cron_delivery_store as bridge, self_wake as sw


class WakeSettlement(unittest.TestCase):
    def test_reserved_terminal_conflict_never_claims_done_or_reposts(self):
        with tempfile.TemporaryDirectory(prefix='wake-conflict-') as scratch:
            home = pathlib.Path(scratch)
            ledger = store.open_ledger(home)
            ledger.execute('''INSERT INTO wake_batches(batch_id,session_id,state,
                canonical_input,batch_keys,created_at,updated_at,owner)
                VALUES('batch','session','reserved','x','[]',100,100,'self:test')''')
            ledger.commit()
            conn = bridge.open_bridge(home)
            sw.ensure_bridge_schema(conn)
            conn.execute('''INSERT INTO selfwake_intents(delivery_key,home,session_id,
                generation,cutoff,reason,batch_id,state,next_attempt_at,created_at,updated_at)
                VALUES(?,?,'session',1,0,'fixture','batch','watching',0,100,100)''',
                         ('a'*64,str(home)))
            conn.commit()
            items = [dict(conn.execute('SELECT * FROM selfwake_intents').fetchone())]
            posts = []

            class Response:
                status = 200
                def __init__(self): self.content = self
                async def __aenter__(self): return self
                async def __aexit__(self,*args): pass
                def __aiter__(self): return self.lines()
                async def lines(self): yield b'event: run.cancelled\n'

            class Session:
                def __init__(self,*args,**kwargs): pass
                async def __aenter__(self): return self
                async def __aexit__(self,*args): pass
                def post(self,*args,**kwargs):
                    posts.append(kwargs.get('json'))
                    return Response()

            def unavailable(*args): raise RuntimeError('isolated registry')
            registry = types.SimpleNamespace(acquire=unavailable, release_or_close=lambda *args:None)
            http = types.SimpleNamespace(ClientSession=Session, ClientTimeout=lambda **kwargs:None)
            worker = sw.SelfWakeWorker(home)
            with patch.dict(sys.modules,{'aiohttp':http,'hermes_state_registry':registry}), \
                    patch.object(sw,'endpoint',return_value=('http://fixture.invalid',{})):
                asyncio.run(worker._dispatch(items,'session','batch'))
                after = dict(conn.execute('SELECT * FROM selfwake_intents').fetchone())
                self.assertEqual(after['state'],'watching')
                self.assertEqual(after['detail'],'ledger-settlement-conflict')
                asyncio.run(worker._dispatch([after],'session','batch'))
            self.assertEqual(len(posts),1)
            self.assertEqual(store.receipt(home,batch_id='batch',resolved='session')
                             ['receipt']['state'],'reserved')
            self.assertEqual(ledger.execute("SELECT count(*) FROM selfwake_audit WHERE phase='terminal'")
                             .fetchone()[0],0)
            store.reset()
            bridge.reset()


if __name__ == '__main__': unittest.main()
