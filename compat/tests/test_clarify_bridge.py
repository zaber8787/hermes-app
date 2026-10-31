"""Run in the Hermes environment; deliberately not executed in the editing sandbox."""
import asyncio
import importlib.util
import json
from pathlib import Path
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
