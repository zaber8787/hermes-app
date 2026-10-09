"""Proof-only historical wake settlement; never releases claims or launches runs."""
from __future__ import annotations

import json
import math
import sqlite3
import time
from contextlib import closing
from pathlib import Path

from . import auto_wake_store as store

TERMINAL_STATUSES = frozenset({'completed', 'failed', 'cancelled'})


def batch_candidates(home: Path, *, after='', limit=4, batch_ids=None):
    """Stable bounded page independent of intent _due; foreign owners are excluded."""
    conn = store.open_ledger(home)
    clause, args = '', []
    if batch_ids is not None:
        if not batch_ids:
            return []
        if len(batch_ids) > 32:
            raise ValueError('at most 32 explicit batches')
        clause = ' AND batch_id IN (' + ','.join('?' for _ in batch_ids) + ')'
        args = list(batch_ids)
    with store.LEDGER_LOCK:
        return [dict(r) for r in conn.execute(
            "SELECT * FROM wake_batches WHERE state IN ('reserved','dispatching','accepted')"
            " AND owner LIKE 'self:%' AND batch_id > ?" + clause +
            ' ORDER BY batch_id LIMIT ?', (after, *args, max(1, min(limit, 32))))]


def _run_proof(batch, snapshot):
    if not isinstance(snapshot, dict):
        return None
    stamp = snapshot.get('updated_at')
    if (not batch['run_id'] or snapshot.get('run_id') != batch['run_id']
            or snapshot.get('session_id') != batch['session_id']
            or snapshot.get('status') not in TERMINAL_STATUSES
            or isinstance(stamp, bool) or not isinstance(stamp, (int, float))
            or not math.isfinite(stamp) or stamp < batch['created_at']
            or stamp > time.time() + 30):
        return None
    return {'kind': 'run-terminal', 'status': snapshot['status'],
            'terminal_at': float(stamp), 'target_state': 'terminal'}


def done_intent_evidence(home, batch):
    """Closed bookkeeping evidence, NOT proof that a model run completed.

    Used for explicit operator settlement only; every claimed key must have
    a matching, absorbing done intent in this profile and batch.
    """
    path = Path(home).resolve() / 'cron_bridge.db'
    if not path.exists():
        return None
    try:
        keys = json.loads(batch['batch_keys'])
        if not isinstance(keys, list) or not keys or len(set(keys)) != len(keys):
            return None
        ledger = store.open_ledger(home)
        with store.LEDGER_LOCK:
            claims = list(ledger.execute('''SELECT delivery_key,session_id,state,ignored
                FROM wake_consumption WHERE batch_id=?''', (batch['batch_id'],)))
        if ({r['delivery_key'] for r in claims} != set(keys)
                or any(r['session_id'] != batch['session_id'] or r['state'] != 'consumed'
                       or r['ignored'] for r in claims)):
            return None
        with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as bridge:
            bridge.row_factory = sqlite3.Row
            rows = [dict(r) for r in bridge.execute('''SELECT delivery_key,home,session_id,
                state,updated_at FROM selfwake_intents WHERE batch_id=?
                ORDER BY delivery_key''', (batch['batch_id'],))]
        if ({r['delivery_key'] for r in rows} != set(keys)
                or any(r['state'] != 'done' or Path(r['home']).resolve() != Path(home).resolve()
                       or r['session_id'] != batch['session_id']
                       or not isinstance(r['updated_at'], (int,float))
                       or not math.isfinite(r['updated_at'])
                       or r['updated_at'] < batch['created_at']
                       or r['updated_at'] > time.time() + 30 for r in rows)):
            return None
        return {'kind':'done-intents', 'status':'done',
                'terminal_at':max(r['updated_at'] for r in rows),
                'target_state':'uncertain-consumed',
                'intents':[{'delivery_key':r['delivery_key'], 'state':r['state'],
                            'updated_at':r['updated_at']} for r in rows]}
    except (sqlite3.Error, ValueError, TypeError, KeyError):
        return None


def _settle(home, batch, proof):
    conn = store.open_ledger(home)
    now = time.time()
    with store.LEDGER_LOCK, conn:
        conn.execute('BEGIN IMMEDIATE')
        current = conn.execute('SELECT * FROM wake_batches WHERE batch_id=?',
                               (batch['batch_id'],)).fetchone()
        if current is None or any(current[k] != batch[k] for k in
                                  ('state', 'run_id', 'session_id', 'owner', 'updated_at',
                                   'batch_keys', 'created_at')):
            return 'conflict'
        if proof['kind'] == 'done-intents' and done_intent_evidence(home, batch) != proof:
            return 'conflict'
        conn.execute('''CREATE TABLE IF NOT EXISTS wake_reconciliations(
            batch_id TEXT PRIMARY KEY, prior_state TEXT NOT NULL, run_id TEXT,
            proof_kind TEXT NOT NULL, proof_status TEXT NOT NULL,
            terminal_at REAL NOT NULL, reconciled_at REAL NOT NULL, proof_details TEXT)''')
        if 'proof_details' not in {r[1] for r in conn.execute('PRAGMA table_info(wake_reconciliations)')}:
            conn.execute('ALTER TABLE wake_reconciliations ADD COLUMN proof_details TEXT')
        conn.execute('''UPDATE wake_batches SET state=?,terminal_at=?,updated_at=?,reason=?
            WHERE batch_id=?''', (proof['target_state'], proof['terminal_at'], now,
                                  'reconciled-' + proof['kind'], batch['batch_id']))
        conn.execute('INSERT INTO wake_reconciliations VALUES(?,?,?,?,?,?,?,?)',
                     (batch['batch_id'], batch['state'], batch['run_id'], proof['kind'],
                      proof['status'], proof['terminal_at'], now, json.dumps(proof)))
        conn.execute('''INSERT INTO selfwake_audit
            (at,session_resolved,trigger,batch_id,run_id,phase,from_state,to_state,reason)
            VALUES(?,?,'self',?,?,'reconcile',?,?,?)''',
                     (now,batch['session_id'],batch['batch_id'],batch['run_id'],
                      batch['state'],proof['target_state'],'proved-' + proof['kind']))
    return 'settled'


def reconcile_batches(home: Path, observe_run, *, dry_run=True, after='', limit=4,
                      batch_ids=None, allow_done_intents=False):
    """A trusted, profile-scoped GET observer supplies run snapshots, never text guesses.

    Unknown, missing, live and mismatched snapshots leave the ledger intact.
    Ledger evidence and settlement commit together; bridge intents are not reopened.
    """
    batches = batch_candidates(home, after=after, limit=limit, batch_ids=batch_ids)
    rows = []
    for batch in batches:
        try:
            proof = _run_proof(batch, observe_run(batch)) if batch['run_id'] else None
        except Exception:
            proof = None
        if proof is None and allow_done_intents:
            proof = done_intent_evidence(home, batch)
        result = 'unresolved'
        if proof is not None:
            result = 'planned' if dry_run else _settle(home, batch, proof)
        rows.append({'batch_id':batch['batch_id'], 'session_id':batch['session_id'],
                     'run_id':batch['run_id'], 'prior_state':batch['state'],
                     'result':result, 'proof':proof})
    return {'rows':rows, 'next_cursor':batches[-1]['batch_id'] if len(batches) == limit else ''}
