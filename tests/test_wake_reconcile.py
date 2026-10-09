"""Historical wake settlement at the receipt/admission boundary."""
import json
import pathlib
import sqlite3
import tempfile
import unittest

from compat import auto_wake_store as store


class StateDB:
    def __init__(self):
        self.conn = sqlite3.connect(':memory:')
        self.conn.row_factory = sqlite3.Row
        self.conn.executescript('''
            CREATE TABLE sessions(id, parent_session_id, end_reason);
            CREATE TABLE messages(id, session_id, timestamp, content, role,
                                  display_kind, display_metadata);
            CREATE TABLE session_turn_leases(conversation_id, expires_at);
            INSERT INTO sessions VALUES('session',NULL,NULL);
        ''')

    def get_session(self, sid):
        return {'source': 'api_server'} if sid == 'session' else None

    def _read_all(self, sql, args):
        return self.conn.execute(sql, args).fetchall()

    def _session_turn_lease_key(self, sid):
        return sid


class ReconcileBatches(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wakelatch-')
        self.home = pathlib.Path(self.tmp.name).resolve()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(store.reset)
        store.configure(reviewed=True)
        self.ledger = store.open_ledger(self.home)
        self.db = StateDB()
        self.addCleanup(self.db.conn.close)
        self.key = 'a' * 64
        self.ledger.execute('''INSERT INTO wake_batches
            (batch_id,session_id,state,run_id,canonical_input,batch_keys,
             created_at,updated_at,owner)
            VALUES('zombie','session','accepted','run-old','x','[]',100,101,'self:test')''')
        self.ledger.commit()
        self.db.conn.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?)',
                             (1,'session',300,'external report','user',
                              'internal_notification',json.dumps({'hermes_app_cron':
                               {'schema':1,'delivery_key':self.key}})))

    def admission(self):
        return store.admit(self.home, session_id='session', resolved='session',
                           keys=[self.key], db=self.db, now=5000, owner='self:new')

    def proof(self, batch):
        return {'run_id':'run-old','session_id':'session','status':'completed',
                'updated_at':200}

    def test_proved_terminal_zombie_does_not_lock_new_same_session_report(self):
        from compat.wake_reconcile import reconcile_batches
        self.assertEqual(self.admission()['rejected'][0]['reason'], 'causal_suspect')
        result = reconcile_batches(self.home, self.proof, dry_run=False)
        self.assertEqual(result['rows'][0]['result'], 'settled')
        receipt = store.receipt(self.home, batch_id='zombie', resolved='session')['receipt']
        self.assertEqual(receipt['state'], 'terminal')
        self.assertEqual(receipt['terminal_at'], 200)
        self.assertEqual(reconcile_batches(self.home, self.proof, dry_run=False)['rows'], [])
        self.assertEqual(self.admission()['status'], 'admitted')

    def test_unknown_or_mismatched_run_never_clears_the_latch(self):
        from compat.wake_reconcile import reconcile_batches
        for snapshot in (None, {}, dict(self.proof(None), status='running'),
                         dict(self.proof(None), run_id='other'),
                         dict(self.proof(None), session_id='other'),
                         dict(self.proof(None), updated_at=float('nan'))):
            result = reconcile_batches(self.home, lambda batch: snapshot, dry_run=False)
            self.assertEqual(result['rows'][0]['result'], 'unresolved')
            self.assertEqual(store.receipt(self.home, batch_id='zombie',
                                           resolved='session')['receipt']['state'], 'accepted')

    def test_dry_run_and_foreign_batches_are_not_mutated(self):
        from compat.wake_reconcile import reconcile_batches
        self.assertEqual(reconcile_batches(self.home, self.proof)['rows'][0]['result'], 'planned')
        self.assertEqual(store.receipt(self.home, batch_id='zombie',
                                       resolved='session')['receipt']['state'], 'accepted')
        self.ledger.execute("UPDATE wake_batches SET owner=NULL")
        self.ledger.commit()
        self.assertEqual(reconcile_batches(self.home, self.proof, dry_run=False)['rows'], [])

    def done_fixture(self, state='accepted', detail='uncertain-consumed'):
        key = 'b' * 64
        self.ledger.execute('UPDATE wake_batches SET state=?,batch_keys=? WHERE batch_id=?',
                            (state,json.dumps([key]),'zombie'))
        self.ledger.execute('''INSERT INTO wake_consumption
            (delivery_key,batch_id,session_id,ignored,state,created_at,updated_at)
            VALUES(?,'zombie','session',0,'consumed',100,100)''', (key,))
        self.ledger.commit()
        bridge = sqlite3.connect(self.home / 'cron_bridge.db')
        bridge.execute('''CREATE TABLE selfwake_intents(delivery_key TEXT PRIMARY KEY,
            home TEXT,session_id TEXT,batch_id TEXT,state TEXT,detail TEXT,
            updated_at REAL)''')
        bridge.execute('INSERT INTO selfwake_intents VALUES(?,?,?,?,?,?,?)',
                       (key,str(self.home),'session','zombie','done',detail,250))
        bridge.commit()
        bridge.close()

    def test_explicit_done_intent_settlement_keeps_consumption_and_quota(self):
        from compat.wake_reconcile import reconcile_batches
        self.done_fixture()
        before = list(self.ledger.execute('SELECT * FROM wake_consumption'))
        result = reconcile_batches(self.home, lambda batch:None, dry_run=False,
                                   allow_done_intents=True)
        self.assertEqual(result['rows'][0]['result'], 'settled')
        receipt = store.receipt(self.home, batch_id='zombie', resolved='session')['receipt']
        self.assertEqual(receipt['state'], 'uncertain-consumed')
        self.assertEqual(receipt['terminal_at'], 250)
        self.assertEqual(list(self.ledger.execute('SELECT * FROM wake_consumption')), before)
        self.assertEqual(self.ledger.execute('SELECT created_at FROM wake_batches').fetchone()[0],100)
        self.assertEqual(reconcile_batches(self.home, lambda batch:None, dry_run=False,
                                          allow_done_intents=True)['rows'], [])

    def test_done_intents_do_not_authorize_automatic_or_incomplete_cleanup(self):
        from compat.wake_reconcile import reconcile_batches
        self.done_fixture(state='reserved', detail='run.cancelled')
        self.assertEqual(reconcile_batches(self.home, lambda b:None, dry_run=False)
                         ['rows'][0]['result'], 'unresolved')
        bridge = sqlite3.connect(self.home/'cron_bridge.db')
        bridge.execute("UPDATE selfwake_intents SET state='watching'")
        bridge.commit()
        bridge.close()
        result = reconcile_batches(self.home, lambda batch:None, dry_run=False,
                                   allow_done_intents=True)
        self.assertEqual(result['rows'][0]['result'],'unresolved')
        self.assertEqual(store.receipt(self.home,batch_id='zombie',resolved='session')
                         ['receipt']['state'],'reserved')

    def test_proof_observation_cannot_overwrite_a_concurrent_settlement(self):
        from compat.wake_reconcile import reconcile_batches
        def observed(batch):
            store.report(self.home,batch_id='zombie',resolved='session',state='uncertain',now=220)
            return self.proof(batch)
        result = reconcile_batches(self.home,observed,dry_run=False)
        self.assertEqual(result['rows'][0]['result'],'conflict')
        self.assertEqual(store.receipt(self.home,batch_id='zombie',resolved='session')
                         ['receipt']['state'],'uncertain-consumed')


if __name__ == '__main__':
    unittest.main()
