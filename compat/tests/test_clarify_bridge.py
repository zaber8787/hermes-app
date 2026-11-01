"""Run in the Hermes environment; deliberately not executed in the editing sandbox."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import threading
from types import SimpleNamespace

import pytest
from aiohttp import web
from tools import clarify_gateway as core
from tools.clarify_tool import clarify_tool

spec = importlib.util.spec_from_file_location('patch_clarify', Path(__file__).parents[1] / 'patch_clarify.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setattr(core, 'get_clarify_timeout', lambda: 2)
    # clarify_tool fires observability hooks, and the real invoke_hook loads every
    # plugin under the live HERMES_HOME into this test process: the deployed compat
    # plugin then installs here and, on vnew, imports run_agent, whose
    # hermes_bootstrap re-execs a non-store interpreter and kills the run.
    from hermes_cli import lifecycle
    monkeypatch.setattr(lifecycle, 'invoke_hook', lambda *a, **k: [])
    def error(message, status, **extra):
        return web.json_response({'error': dict(message=message, **extra)}, status=status)
    bridge = p.Bridge(SimpleNamespace(web=web, _error_response=error), {})
    agent = SimpleNamespace(session_id='sid')
    adapter = SimpleNamespace(_active_run_agents={'run': agent}, _check_auth=lambda r: None,
                              _request_owns_run=lambda r, rid: True)
    events, signal, result = [], threading.Event(), {}
    def sink(name, payload):
        events.append((name, payload))
        if name == 'clarify.request':
            signal.set()
    bridge.run_sinks[(id(adapter), 'run')] = sink
    threads = []
    def start(questions):
        def run():
            result['value'] = json.loads(clarify_tool(questions, lambda qs: bridge.callback(adapter, agent, qs)))
        thread = threading.Thread(target=run)
        threads.append(thread)
        thread.start()
        assert signal.wait(2)
        return events[0][1]
    def request(cid=None, answers=None, sid='sid'):
        async def body():
            return {'answers': answers}
        return SimpleNamespace(match_info=dict(sid=sid, **({'clarify_id': cid} if cid else {})), json=body)
    yield SimpleNamespace(bridge=bridge, adapter=adapter, events=events, result=result, start=start,
                          request=request, threads=threads)
    core.clear_session('run')
    for thread in threads:
        thread.join(3)
        assert not thread.is_alive()


def call(env, request):
    return asyncio.run(env.bridge.handle(env.adapter, request))


def finish(env):
    env.threads[0].join(3)
    assert not env.threads[0].is_alive()
    return env.result['value']


def test_register_rest_response_and_pending_reconnect(env):
    form = env.start([{'question': 'Name?'}, {'question': 'Pick', 'choices': ['A', 'B']}])
    assert core.has_pending('run')
    for _ in range(2):  # bootstrap and reconnect use the same pending GET
        response = call(env, env.request())
        assert json.loads(response.body)['pending'] == [form]
    assert call(env, env.request(form['clarify_id'], {'q0': 'Z'})).status == 422
    response = call(env, env.request(form['clarify_id'], {'q0': 'Z', 'q1': 'B'}))
    assert response.status == 200
    result = finish(env)
    assert result['outcome'] == 'answered'
    assert [r['user_response'] for r in result['responses']] == ['Z', 'B']
    assert env.events[-1][0] == 'clarify.resolved'
    assert json.loads(call(env, env.request()).body) == {'pending': []}
    assert call(env, env.request(form['clarify_id'], {})).status == 404


def test_choice_requires_choice_and_other_is_text_mode(env):
    form = env.start([{'question': 'Pick', 'choices': ['A', 'B']}])
    cid = form['clarify_id']
    bad = call(env, env.request(cid, {'q0': 'free prose'}))
    assert bad.status == 409
    assert json.loads(bad.body)['error']['code'] == 'clarify_choice_required'
    entry = env.bridge.forms[cid]['entries'][0][1]
    assert not entry.event.is_set()
    assert call(env, env.request(cid, {'q0': 'other:custom'})).status == 200
    assert entry.awaiting_text
    assert finish(env)['responses'][0]['user_response'] == 'custom'


def test_timeout_cleans_all_entries(env, monkeypatch):
    monkeypatch.setattr(core, 'get_clarify_timeout', lambda: 0.03)
    env.start([{'question': 'First'}, {'question': 'Second'}])
    assert finish(env)['outcome'] == 'timed_out'
    assert not core.has_pending('run')
    assert env.events[-1][1]['outcome'] == 'timed_out'


def test_multiselect_skip_and_wrong_session(env):
    form = env.start([{'question': 'Pick', 'choices': ['A', 'B'], 'multi_select': True}, {'question': 'Why?'}])
    assert call(env, env.request(form['clarify_id'], {}, sid='other')).status == 404
    assert call(env, env.request(form['clarify_id'], {'q0': 'A,B', 'q1': 'skip'})).status == 200
    result = finish(env)
    assert result['responses'][0]['user_response'] == ['A', 'B']
    assert result['responses'][1]['status'] == 'skipped'


THREAD = '20260910_151843_94d2209a'
THREAD_PRINCIPAL = 'automation:agent:main:discord:thread:1'


# TASK-CLARIFYUI: an `api_...` session runs on core's session authority, whose TurnRunner
# replaces agent.clarify_callback; its questions live only in PendingControls.
@pytest.fixture
def authority(env, monkeypatch):
    import sqlite3
    from contextlib import contextmanager
    from gateway.session_pending_controls import PendingControls
    # Importing gateway.run re-executes the interpreter; PendingControls only needs its redactor.
    monkeypatch.setitem(sys.modules, 'gateway.run', SimpleNamespace(_redact_approval_command=str))
    conn = sqlite3.connect(':memory:')
    conn.row_factory = sqlite3.Row
    conn.execute('CREATE TABLE session_admissions (admission_id, request_id, principal_id, target_session_id,'
                 ' lineage_json, payload_json, payload_digest, status, generation)')
    # TASK-CLARIFYUI round 2: a Discord thread's turn is an automation (or messaging) admission,
    # not an API one; a cron-owner turn has no owner principal the app may answer for.
    rows = [('adm', 'run_api', 'api', 'api_1', 3), ('adm_t', 'req_thread', THREAD_PRINCIPAL, THREAD, 5),
            ('adm_m', 'req_msg', 'messaging:[null,"discord","1"]', 'msg_1', 2),
            ('adm_c', 'req_cron', 'cron-owner', 'cron_1', 1)]
    for adm, rid, principal, sid, gen in rows:
        conn.execute("INSERT INTO session_admissions VALUES (?, ?, ?, ?, '{}', '{}', '', 'started', ?)",
                     (adm, rid, principal, sid, gen))
    generations = {sid: gen for _, _, _, sid, gen in rows}
    def controls_for():
        return PendingControls(SimpleNamespace(lock=threading.RLock(), publish=lambda *a, **k: None))
    sessions = {sid: SimpleNamespace(controls=controls_for()) for sid in generations}
    controls = sessions['api_1'].controls
    db = SimpleNamespace(_read_ctx=contextmanager(lambda: (yield conn)))
    actors = []
    class Fake:
        # attach/respond/detach as session_authority checks them: the actor must be subscribed.
        profile_id = 'default'
        subscribers = {}
        async def attach(self, actor, ref):
            assert ref.profile_id == actor.profile_id == 'default' and 'session:respond' in actor.capabilities
            actors.append((actor, ref.session_id))
            self.subscribers[actor.transport_id] = actor
            live = sessions[ref.session_id].controls
            return SimpleNamespace(subscription_id=actor.transport_id,
                                   prompts=live.snapshot(ref.session_id, generations[ref.session_id]))
        async def respond(self, actor, ref, generation, prompt_id, response, *, kind):
            assert self.subscribers.get(actor.transport_id) == actor
            return sessions[ref.session_id].controls.respond(ref.session_id, generation, prompt_id,
                                                             response, kind=kind)
        async def detach(self, actor, subscription_id):
            del self.subscribers[subscription_id]
    fake = Fake()
    fake.sessions, fake.db = sessions, db
    monkeypatch.setattr(p, '_authority', lambda adapter: fake)
    async def respond(adapter, run_id, body):
        assert run_id == 'run_api'
        return controls.respond('api_1', body['execution_generation'], body['request_id'],
                                {'answer': body['answer']}, kind='clarify')
    monkeypatch.setattr(p, '_respond', respond)
    waits = []
    def ask(cid, question, choices=None, multi_select=False, sid='api_1'):
        entry = core.register(cid, 'api-key', question, choices, multi_select)
        sessions[sid].controls.register_clarify(sid, generations[sid], entry, timeout_s=600)
        result = {}
        thread = threading.Thread(target=lambda: result.update(value=core.wait_for_response(cid, 2)))
        thread.start()
        waits.append(thread)
        def answered():
            thread.join(3)
            return result['value']
        return answered
    yield SimpleNamespace(ask=ask, controls=controls, actors=actors, fake=fake)
    core.clear_session('api-key')
    for thread in waits:
        thread.join(3)


def test_authority_prompt_is_pending_and_answer_resumes_turn(env, authority):
    result = authority.ask('c1', 'Which chapter?', ['Ch1', 'Ch2'])
    pending = json.loads(call(env, env.request(sid='api_1')).body)['pending']
    assert pending == [{'clarify_id': 'c1', 'session_id': 'api_1', 'run_id': 'run_api', 'timeout_seconds': 600,
                        'questions': [{'qid': 'c1', 'clarify_id': 'c1', 'question': 'Which chapter?',
                                       'choices': ['Ch1', 'Ch2'], 'multi_select': False}]}]
    bad = call(env, env.request('c1', {'c1': 'prose'}, sid='api_1'))
    assert bad.status == 409 and json.loads(bad.body)['error']['code'] == 'clarify_choice_required'
    assert call(env, env.request('c1', {'c1': 'ch2'}, sid='api_1')).status == 200
    assert result() == 'Ch2'
    assert json.loads(call(env, env.request(sid='api_1')).body) == {'pending': []}
    assert call(env, env.request('c1', {'c1': 'Ch1'}, sid='api_1')).status == 404


def test_authority_multiselect_other_and_ownership(env, authority):
    multi = authority.ask('m1', 'Topics', ['A', 'B', 'C'], multi_select=True)
    free = authority.ask('o1', 'Pick', ['X'])
    assert call(env, env.request('m1', {'m1': 'A,C'}, sid='other')).status == 404
    assert call(env, env.request('m1', {'m1': 'A,C'}, sid='api_1')).status == 200
    assert call(env, env.request('o1', {'o1': 'other:my own'}, sid='api_1')).status == 200
    assert json.loads(multi()) == ['A', 'C']
    assert free() == 'my own'
    authority.ask('h1', 'Hidden?')
    env.adapter._request_owns_run = lambda r, rid: False
    assert json.loads(call(env, env.request(sid='api_1')).body) == {'pending': []}
    assert call(env, env.request('h1', {'h1': 'x'}, sid='api_1')).status == 404


def test_discord_thread_prompt_is_pending_and_answer_resumes_turn(env, authority):
    # Red before round 2: the admission query was pinned to principal_id='api', so pending was [].
    result = authority.ask('t1', 'Which chapter?', ['Ch1', 'Ch2'], sid=THREAD)
    # An API run the caller does not own stays hidden; the thread turn is the owner's own.
    env.adapter._request_owns_run = lambda r, rid: False
    pending = json.loads(call(env, env.request(sid=THREAD)).body)['pending']
    assert pending == [{'clarify_id': 't1', 'session_id': THREAD, 'run_id': 'req_thread', 'timeout_seconds': 600,
                        'questions': [{'qid': 't1', 'clarify_id': 't1', 'question': 'Which chapter?',
                                       'choices': ['Ch1', 'Ch2'], 'multi_select': False}]}]
    # The prompt is keyed by its own session: another session id neither lists nor answers it.
    assert json.loads(call(env, env.request(sid='api_1')).body) == {'pending': []}
    assert call(env, env.request('t1', {'t1': 'Ch1'}, sid='msg_1')).status == 404
    bad = call(env, env.request('t1', {'t1': 'prose'}, sid=THREAD))
    assert bad.status == 409 and json.loads(bad.body)['error']['code'] == 'clarify_choice_required'
    assert call(env, env.request('t1', {'t1': 'ch2'}, sid=THREAD)).status == 200
    assert result() == 'Ch2'
    actor, sid = authority.actors[-1]
    assert sid == THREAD and actor.capabilities == frozenset({'session:read', 'session:respond'})
    assert authority.fake.subscribers == {}  # detached after answering
    assert json.loads(call(env, env.request(sid=THREAD)).body) == {'pending': []}
    assert call(env, env.request('t1', {'t1': 'Ch1'}, sid=THREAD)).status == 404


def test_messaging_principal_lists_and_unknown_principal_fails_closed(env, authority):
    authority.ask('g1', 'Go?', ['yes', 'no'], sid='msg_1')
    authority.ask('k1', 'Cron?', ['yes'], sid='cron_1')
    listed = json.loads(call(env, env.request(sid='msg_1')).body)['pending']
    assert [f['clarify_id'] for f in listed] == ['g1']
    assert call(env, env.request('g1', {'g1': 'no'}, sid='msg_1')).status == 200
    assert json.loads(call(env, env.request(sid='cron_1')).body) == {'pending': []}
    assert call(env, env.request('k1', {'k1': 'yes'}, sid='cron_1')).status == 404
    core.resolve_gateway_clarify('k1', core.CANCELLED)
