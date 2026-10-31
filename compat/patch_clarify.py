"""API-server clarify callback. All forms and sinks are process-local, per load."""
from functools import wraps
import asyncio
import json
import threading
import time
from uuid import uuid4


class Bridge:
    def __init__(self, api, state):
        self.api, self.state = api, state
        self.forms = {}
        self.lock = threading.RLock()
        self.run_sinks = state.setdefault('clarify_run_sinks', {})
        self.closed = False

    def callback(self, adapter, agent, questions):
        from tools import clarify_gateway as core
        run_id = next((r for r, a in adapter._active_run_agents.copy().items() if a is agent), None)
        sid = getattr(agent, 'session_id', None)
        sink = self.run_sinks.get((id(adapter), run_id))
        if run_id is None or not sid or sink is None:
            raise RuntimeError('Clarify requires an active API run and event sink')
        timeout = core.get_clarify_timeout()
        form_id = uuid4().hex[:10]
        entries = []
        payload = dict(clarify_id=form_id, session_id=sid, run_id=run_id,
                       questions=[], timeout_seconds=timeout, issued_at=time.time())
        answers, outcome = {}, 'answered'
        with self.lock:
            if self.closed:
                raise RuntimeError('Clarify bridge unloaded')
            for q in questions:
                cid = uuid4().hex[:10]
                entry = core.register(cid, run_id, q['question'], q.get('choices'), q.get('multi_select', False))
                entries.append((q['qid'], entry))
                payload['questions'].append(dict(qid=q['qid'], clarify_id=cid, question=q['question'],
                                                choices=q.get('choices'), multi_select=q.get('multi_select', False)))
            form = dict(payload=payload, entries=entries, adapter=adapter, submitted=False)
            self.forms[form_id] = form
            sink('clarify.request', payload)
        deadline = time.monotonic() + timeout if timeout > 0 else None
        try:
            for qid, entry in entries:
                remaining = max(0.001, deadline - time.monotonic()) if deadline else timeout
                response = core.wait_for_response(entry.clarify_id, remaining)
                if response is None:
                    outcome = 'timed_out'
                    break
                if response == core.CANCELLED:
                    outcome = 'cancelled'
                    break
                answers[qid] = None if response == core.SKIPPED else response
        finally:
            with self.lock:
                self.forms.pop(form_id, None)
                # Dispose unvisited entries without touching another form's entries.
                for _, entry in entries:
                    core.resolve_gateway_clarify(entry.clarify_id, core.CANCELLED)
                    core.wait_for_response(entry.clarify_id, 0.001)
                sink('clarify.resolved', dict(clarify_id=form_id, session_id=sid,
                                             outcome=outcome, answered_at=time.time()))
        return dict(answers=answers, outcome=outcome)

    def pending(self, adapter, sid, request):
        return [f['payload'] for f in self.forms.values()
                if f['adapter'] is adapter and f['payload']['session_id'] == sid
                and not f['submitted'] and adapter._request_owns_run(request, f['payload']['run_id'])]

    async def handle(self, adapter, request):
        from tools import clarify_gateway as core
        err = adapter._check_auth(request)
        if err is not None:
            return err
        sid = request.match_info['sid']
        cid = request.match_info.get('clarify_id')
        if cid is None:
            with self.lock:
                return self.api.web.json_response({'pending': self.pending(adapter, sid, request)})
        try:
            body = await request.json()
        except Exception:
            return self.api._error_response('Invalid JSON', 422)
        with self.lock, core._lock:
            form = self.forms.get(cid)
            if (form is None or form['adapter'] is not adapter or form['submitted']
                    or form['payload']['session_id'] != sid
                    or not adapter._request_owns_run(request, form['payload']['run_id'])):
                return self.api._error_response('Unknown clarify form', 404)
            answers = body.get('answers') if isinstance(body, dict) else None
            if not isinstance(answers, dict) or any(qid not in answers for qid, _ in form['entries']):
                return self.api._error_response('Every question requires an answer', 422)
            values = []
            for qid, entry in form['entries']:
                raw = answers[qid]
                if not isinstance(raw, str):
                    return self.api._error_response('Answers must be strings', 422)
                if raw.startswith('other:'):
                    value = raw[6:]
                elif raw.casefold() == 'skip':
                    value = core.SKIPPED
                elif entry.choices:
                    tokens = raw.split(',') if entry.multi_select else [raw]
                    labels = [core._match_label(t.strip(), entry.choices) for t in tokens]
                    if not labels or any(v is None for v in labels):
                        return self.api._error_response('Choose an option or use other:', 409,
                                                        code='clarify_choice_required')
                    value = json.dumps(labels, ensure_ascii=False) if entry.multi_select else labels[0]
                else:
                    value = raw
                if entry.event.is_set():
                    return self.api._error_response('Clarify already resolved', 404)
                values.append((entry, raw, value))
            for entry, raw, value in values:
                if raw.startswith('other:'):
                    core.mark_awaiting_text(entry.clarify_id)
                if not core.resolve_gateway_clarify(entry.clarify_id, value):
                    return self.api._error_response('Clarify expired', 404)
            form['submitted'] = True
        return self.api.web.json_response({'clarify_id': cid, 'outcome': 'answered'})


def install(api, state, tx):
    """Transactional bindings use compat's shared owner/unload lifecycle."""
    from gateway.platforms import api_server_runs as runs
    bridge = Bridge(api, state)
    cls = api.APIServerAdapter
    old_create, old_routes, old_caps = cls._create_agent, cls._http_route_table, cls._handle_capabilities
    old_status = cls._set_run_status

    @wraps(old_create)
    def create(self, *args, **kwargs):
        agent = old_create(self, *args, **kwargs)
        agent.clarify_callback = lambda questions: bridge.callback(self, agent, questions)
        return agent

    @wraps(old_status)
    def status(self, run_id, status, **fields):
        result = old_status(self, run_id, status, **fields)
        key = (id(self), run_id)
        if status in {'completed', 'failed', 'cancelled', 'interrupted'}:
            bridge.run_sinks.pop(key, None)
            from tools import clarify_gateway as core
            with bridge.lock:
                for form in list(bridge.forms.values()):
                    if form['adapter'] is self and form['payload']['run_id'] == run_id:
                        for _, entry in form['entries']:
                            core.resolve_gateway_clarify(entry.clarify_id, core.CANCELLED)
        elif key not in bridge.run_sinks:
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                return result
            def emit(name, payload):
                def publish():
                    mirror = state.get('approval_queues', {}).get(key)
                    if mirror is not None:
                        mirror.enqueue(name, payload)
                    stream = self._run_streams.get(run_id)
                    if stream is not None:
                        stream.put_nowait(runs._run_event(run_id, name, **{k: v for k, v in payload.items() if k != 'run_id'}))
                loop.call_soon_threadsafe(publish)
            bridge.run_sinks[key] = emit
        return result

    async def handle(self, request):
        return await bridge.handle(self, request)

    @wraps(old_routes)
    def routes(self):
        rows = list(old_routes(self))
        for method, path in [('GET', '/v1/sessions/{sid}/clarify'),
                             ('POST', '/v1/sessions/{sid}/clarify/{clarify_id}')]:
            if not any((m, p) == (method, path) for m, p, _ in rows):
                rows.append((method, path, self._handle_session_clarify))
        return rows

    @wraps(old_caps)
    async def caps(self, request, **kwargs):
        response = await old_caps(self, request, **kwargs)
        if response.status == 200:
            payload = json.loads(response.body)
            payload.setdefault('features', {})['clarify'] = True
            return api.web.json_response(payload)
        return response

    def close():
        from tools import clarify_gateway as core
        with bridge.lock:
            bridge.closed = True
            for form in bridge.forms.values():
                for _, entry in form['entries']:
                    core.resolve_gateway_clarify(entry.clarify_id, core.CANCELLED)
            bridge.run_sinks.clear()
    tx.cleanups.append(close)
    tx.set(cls, '_create_agent', create)
    tx.set(cls, '_set_run_status', status)
    tx.set(cls, '_handle_session_clarify', handle)
    tx.set(cls, '_http_route_table', routes)
    tx.set(cls, '_handle_capabilities', caps)
    return bridge
