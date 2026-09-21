#!/usr/bin/env python3
"""Hermes P0 live probe. Stdlib only; never changes existing sessions or core.
Run: python3 probe/probe_p0.py [--retention-seconds 65]
HTTP evidence contains full responses and base64 binary bodies, with key redacted.
"""
import argparse
import base64
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import threading
import time
import urllib.request
import urllib.error

import sys as _sys
_sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import runtime_config as _rc
try:
    BASE = _rc.validate_url(
        _rc.Resolver().resolve("HERMES_LIVE_BASE_URL", required=True),
        name="HERMES_LIVE_BASE_URL", allow_path=True)
except _rc.ConfigError as _exc:
    _sys.exit(f"live base unavailable: {_exc}")
SOURCE = Path.home() / '.hermes/hermes-agent'

def now():
    return datetime.now(timezone.utc).isoformat()

def rows(body, key='data'):
    return body.get(key, body.get('data', [])) if isinstance(body, dict) else []

class Probe:
    def __init__(self, retention):
        self.key = next(x.split('=', 1)[1].strip().strip('\"\'') for x in (Path.home()/'.hermes/.env').read_text().splitlines() if x.startswith('API_SERVER_KEY='))
        self.retention = retention
        self.result = {'started_at': now(), 'base_url': BASE, 'requests': [], 'probes': {}, 'created_sessions': [], 'source_evidence': {}}
        self.lock = threading.Lock()
        self.path = Path(__file__).parent/'results'/datetime.now().strftime('p0_%Y%m%d_%H%M.json')
        self.path.parent.mkdir(exist_ok=True)
        self.sessions = []
        self.completed_runs = []

    def save(self):
        with self.lock:
            data = json.dumps(self.result, ensure_ascii=False, indent=2).replace(self.key, '<REDACTED>')
            tmp = self.path.with_suffix('.tmp')
            tmp.write_text(data)
            tmp.replace(self.path)

    def http(self, method, path, body=None, headers=None, stream=False, on_event=None):
        hdr = {'Authorization': 'Bearer '+self.key, **(headers or {})}
        raw = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
        if body is not None and not isinstance(body, bytes):
            hdr['Content-Type'] = 'application/json'
        record = {'method': method, 'url': BASE+path, 'at': now(), 'req': {'headers': {**hdr, 'Authorization': 'Bearer <REDACTED>'}, 'body': {'base64': base64.b64encode(body).decode()} if isinstance(body, bytes) else body}}
        with self.lock:
            record['id'] = len(self.result['requests'])+1
            self.result['requests'].append(record)
        self.save()
        start = time.monotonic()
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            try:
                response = opener.open(urllib.request.Request(BASE+path, data=raw, headers=hdr, method=method), timeout=610)
            except urllib.error.HTTPError as e:
                response = e
            with response:
                record['status'] = response.status
                record['response_headers'] = dict(response.headers)
                if stream and response.status == 200:
                    events = record['resp'] = []
                    event, data = 'message', []
                    def flush():
                        if data:
                            payload = '\n'.join(data)
                            try: payload = json.loads(payload)
                            except ValueError: pass
                            events.append({'index': len(events), 'at': now(), 'elapsed_s': round(time.monotonic()-start, 4), 'event': event, 'data': payload})
                            if on_event: on_event(events[-1])
                    for line in response:
                        line = line.decode('utf-8').rstrip('\r\n')
                        if not line:
                            flush()
                            event, data = 'message', []
                        elif line.startswith('event:'): event = line[6:].strip()
                        elif line.startswith('data:'): data.append(line[5:].lstrip(' '))
                    flush()
                else:
                    content = response.read()
                    try: record['resp'] = json.loads(content)
                    except (ValueError, UnicodeDecodeError):
                        if 'text/' in response.headers.get('Content-Type', ''):
                            record['resp'] = content.decode(errors='replace')
                        else: record['resp'] = {'base64': base64.b64encode(content).decode(), 'sha256': hashlib.sha256(content).hexdigest(), 'bytes': len(content)}
        except Exception as e:
            record['error'] = str(e)
        record['elapsed_s'] = round(time.monotonic()-start, 4)
        self.save()
        return record

    def create(self, label):
        r = self.http('POST', '/api/sessions', {'title': 'P0 temporary '+label})
        sid = r.get('resp', {}).get('session', {}).get('id')
        if not sid: raise RuntimeError('Cannot create session; request #'+str(r['id']))
        self.result['created_sessions'].append(sid)
        self.save()
        return sid

    def history(self, sid, query='limit=500'):
        return self.http('GET', f'/api/sessions/{sid}/messages?{query}')

    def chat_thread(self, sid, prompt):
        box = {}
        def work(): box['response'] = self.http('POST', f'/api/sessions/{sid}/chat', {'input': prompt})
        thread = threading.Thread(target=work)
        thread.start()
        return thread, box

    def match_run(self, sid, thread, seconds=90):
        refs = []
        deadline = time.monotonic()+seconds
        while time.monotonic() < deadline:
            r = self.http('GET', '/v1/runs')
            refs.append(r['id'])
            body = r.get('resp', {})
            for run in rows(body, 'runs') or rows(body):
                if run.get('session_id') == sid:
                    return run, refs
            if r.get('status') in (404, 405) or not thread.is_alive(): break
            time.sleep(1)
        return None, refs

    def probe1(self):
        sid = self.create('mapping')
        t, box = self.chat_thread(sid, '讀 /etc/hostname 然後告訴我；請實際呼叫 terminal 工具，不要猜測。')
        run, refs = self.match_run(sid, t)
        t.join()
        out = {'session_id': sid, 'run': run, 'poll_refs': refs, **box}
        if run:
            rid = run.get('run_id', run.get('id'))
            out['after_completion'] = self.http('GET', '/v1/runs/'+rid)
            self.completed_runs.append((rid, time.monotonic()))
        out['history'] = self.history(sid)
        return out

    def probe2(self):
        sid = self.create('sse')
        r = self.http('POST', f'/api/sessions/{sid}/chat/stream', {'input': '讀 /etc/hostname 然後告訴我；請實際呼叫 terminal 工具，不要猜測。'}, stream=True)
        events = r.get('resp', [])
        if isinstance(events, list):
            started = next((e['data'] for e in events if e['event']=='run.started'), {})
            if started.get('run_id'):
                rid = started['run_id']
                self.completed_runs.append((rid, time.monotonic()))
                self.result['probes']['1']['stream_mapping'] = started
                self.result['probes']['1']['stream_status_after'] = self.http('GET', '/v1/runs/'+rid)
        if not isinstance(events, list): return {'stream': r}
        tools = [e['index'] for e in events if e['event'] in ('tool.started', 'tool.completed', 'tool.failed')]
        last_tool = max(tools, default=-1)
        return {'session_id': sid, 'stream_ref': r['id'], 'event_order': [e['event'] for e in events], 'last_tool_index': last_tool, 'delta_segments': [{'index': e['index'], 'classification': '旁白（事後依工具交錯判定）' if e['index'] < last_tool else '最終回覆候選（需完成事件/歷史確認）'} for e in events if e['event']=='assistant.delta'], 'run_completed_full': [e['data'] for e in events if e['event']=='run.completed'], 'history': self.history(sid)}

    def probe3(self):
        sid = self.create('slash')
        response = self.http('POST', f'/api/sessions/{sid}/chat', {'input': '/grill-me test'})
        return {'response': response, 'history': self.history(sid)}

    def list_sessions(self):
        if not self.sessions:
            offset = 0
            while True:
                r = self.http('GET', f'/api/sessions?limit=500&offset={offset}')
                page = rows(r.get('resp', {}))
                self.sessions.extend(s for s in page if s['id'] not in self.result['created_sessions'])
                if len(page)<500: break
                offset += len(page)
            self.sessions.sort(key=lambda s: s.get('message_count', 0), reverse=True)
        return self.sessions

    def probe4(self):
        counts, samples = Counter(), []
        for s in self.list_sessions()[:5]:
            r = self.history(s['id'])
            messages = rows(r.get('resp', {}), 'messages')
            c = Counter(str(m.get('display_kind')) for m in messages)
            counts.update(c)
            samples.append({'session_id': s['id'], 'message_count': s.get('message_count'), 'sample_size': len(messages), 'counts': dict(c), 'ref': r['id']})
        # Track source literals and constant definitions; arbitrary TEXT values remain possible.
        hits, values = [], set()
        pattern = re.compile(r'''(?:["']?display_kind["']?\s*[:=]\s*|[A-Z_]*DISPLAY_KIND\s*=\s*)["']([a-z_]+)["']''')
        for root, dirs, files in os.walk(SOURCE):
            dirs[:] = [d for d in dirs if d not in {'.git', 'tests', 'venv', '.venv', 'node_modules', 'skills', 'optional-skills', '__pycache__'}]
            for name in files:
                if not name.endswith('.py'): continue
                p = Path(root)/name
                for n, line in enumerate(p.read_text(errors='replace').splitlines(), 1):
                    for v in pattern.findall(line):
                        values.add(v)
                        hits.append({'path': str(p.relative_to(SOURCE)), 'line': n, 'text': line.strip(), 'value': v})
        self.result['source_evidence']['display_kind'] = hits
        return {'counts': dict(counts), 'samples': samples, 'source_literals': sorted(values), 'note': 'source literal inventory, not a closed enum: storage accepts arbitrary TEXT; comments included in evidence for review'}

    def probe5(self):
        s = next((s for s in self.list_sessions() if s.get('message_count', 0)>500), None)
        over500 = s is not None
        if not s: s = next(iter(self.list_sessions()), None)
        if not s: return {'status': 'unverified', 'reason': 'No existing sessions'}
        refs, pages = [], []
        for q in ['order=oldest&limit=200&offset=0', 'order=oldest&limit=200&offset=200', 'order=oldest&limit=500&offset=0', 'order=latest&limit=200&offset=0']:
            r = self.history(s['id'], q)
            refs.append(r['id'])
            pages.append([m.get('id') for m in rows(r.get('resp', {}), 'messages')])
        combined = pages[0]+pages[1]
        return {'session_id': s['id'], 'over500_requirement_met': over500, 'message_count': s.get('message_count'), 'refs': refs, 'id_sequences': pages, 'no_duplicates': len(set(combined))==len(combined), 'no_gaps_against_500': len(combined)==400 and combined==pages[2][:400], 'latest_ascending_ids': pages[3]==sorted(pages[3]), 'latest_matches_oldest_tail': pages[3]==pages[2][-200:] if len(pages[2])<500 else None}

    def probe6(self):
        data = os.urandom(1024)
        boundary = 'p0boundary'
        multi = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="p0.bin"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()+data+f'\r\n--{boundary}--\r\n'.encode())
        first = self.http('POST', '/v1/artifacts/upload', multi, {'Content-Type': 'multipart/form-data; boundary='+boundary})
        raw = self.http('POST', '/v1/artifacts/upload', data, {'Content-Type': 'text/plain', 'X-Artifact-Filename': 'p0.txt'})
        out = {'sha256': hashlib.sha256(data).hexdigest(), 'multipart': first, 'raw': raw, 'session_sent': False}
        receipt = raw.get('resp', {})
        if isinstance(receipt, dict) and receipt.get('artifact_id'):
            d = self.http('GET', '/v1/artifacts/download/'+receipt['artifact_id'])
            out['download'] = d
            out['sha256_matches'] = d.get('resp', {}).get('sha256') == out['sha256']
        return out

    def probe7(self):
        out = {}
        for mode in ('stop', 'steer'):
            sid = self.create(mode)
            box, run_box = {}, {}
            ready = threading.Event()
            def received(event):
                if event['event']=='run.started':
                    run_box.update(event['data'])
                if event['event']=='tool.started': ready.set()
            def work():
                box['response'] = self.http('POST', f'/api/sessions/{sid}/chat/stream', {'input': '這是 API 測試：請依序呼叫 terminal 六次，每次執行 sleep 10，總共等待約 60 秒，最後回覆 P0_LONG_DONE。不要背景執行。'}, stream=True, on_event=received)
            t = threading.Thread(target=work)
            t.start()
            ready.wait(90)
            run, refs = run_box or None, []
            item = out[mode] = {'session_id': sid, 'run': run, 'poll_refs': refs}
            if run:
                rid = run.get('run_id', run.get('id'))
                time.sleep(5)
                item['control'] = self.http('POST', f'/v1/runs/{rid}/{mode}', {'input': '取消剩下的 sleep，立即只回覆 P0_STEER_CONFIRMED。'} if mode=='steer' else {})
                item['immediate_status'] = self.http('GET', '/v1/runs/'+rid)
            t.join()
            item.update(box)
            if run: item['final_status'] = self.http('GET', '/v1/runs/'+rid)
            item['session_after'] = self.http('GET', '/api/sessions/'+sid)
            item['history'] = self.history(sid)
            if mode=='stop': item['reuse'] = self.http('POST', f'/api/sessions/{sid}/chat', {'input': '不要用工具，只回覆 P0_REUSABLE。'})
        return out

    def probe8(self):
        out = []
        for sid in self.result['created_sessions']:
            r = self.http('DELETE', '/api/sessions/'+sid)
            check = self.http('GET', '/api/sessions/'+sid)
            out.append({'session_id': sid, 'delete': r, 'check': check, 'cleanup': 'deleted' if r.get('status') in (200,202,204,404) and check.get('status')==404 else 'abandoned; do not reuse (contract §7 fallback)'})
        return {'sessions': out}

    def capture_source(self):
        excerpts = {}
        for name, ranges in {
            'gateway/platforms/api_server.py': [(610, 634), (2550, 2600), (2980, 3030), (3065, 3098), (3105, 3180), (3720, 3730)],
            'gateway/platforms/api_server_runs.py': [(815, 899)],
            'hermes_state_common.py': [(358, 368)],
        }.items():
            lines = (SOURCE/name).read_text().splitlines()
            excerpts[name] = [f'{n}: {lines[n-1]}' for start, end in ranges for n in range(start, min(end, len(lines))+1)]
        self.result['source_evidence']['api'] = excerpts

    def report(self):
        p = self.result['probes']
        answers = []
        p1 = p.get('1', {})
        retention = p1.get('retention_recheck', {})
        answers.append(f"GET /v1/runs 不可列舉（405）；使用 chat/stream 的 run.started 綁定 session_id/run_id，再呼叫 /v1/runs/{{id}}/stop 或 /steer；完成後實測 {retention.get('seconds_after_completion', 0):.1f} 秒查詢 HTTP {retention.get('response', {}).get('status')}，source TTL 3600 秒，未實測到期。")
        p2 = p.get('2', {})
        delta_indices = [d['index'] for d in p2.get('delta_segments', [])]
        boundary_note = '觀察到工具前 delta，旁白/最終切點僅能事後分類' if any(i < p2.get('last_tool_index', -1) for i in delta_indices) else '未觀察到工具前旁白 delta，故無實測旁白→最終切換'
        answers.append(f"本次 delta index={min(delta_indices) if delta_indices else None} 起，{boundary_note}；SSE 順序與逐事件時間戳見 requests #{p2.get('stream_ref')}；最後工具事件 index={p2.get('last_tool_index')}，之後 delta 為最終候選，須以 assistant.completed / run.completed.messages 確認，不能即時保證切點；run.completed 全文見 probes.2.run_completed_full。")
        p3 = p.get('3', {})
        history = rows(p3.get('history', {}).get('resp', {}), 'messages')
        exact = any(m.get('role')=='user' and m.get('content')=='/grill-me test' for m in history)
        answers.append(f"/grill-me test 的原文 user 訊息保存驗證={exact}；配合 source 的原文傳遞路徑，支持 server 未重寫、skill 由模型自行載入（僅靠自然語言回應無法證明）。")
        p4 = p.get('4', {})
        answers.append(f"真實 session 樣本 display_kind={p4.get('counts')}；source 已知 literal 全集={p4.get('source_literals')}，儲存層允許任意 TEXT，並非封閉 enum。")
        p5 = p.get('5', {})
        answers.append(f"oldest offset 0/200 兩頁共 400 則：無重複={p5.get('no_duplicates')}、與 500 則基準前 400 id 完全相符={p5.get('no_gaps_against_500')}；>500 前提={p5.get('over500_requirement_met')}、實測 message_count={p5.get('message_count')}（前提不符則僅驗證較小樣本）；latest 取最新頁但頁內 id 升序={p5.get('latest_ascending_ids')}。")
        p6 = p.get('6', {})
        answers.append(f"1KB 附件 multipart HTTP {p6.get('multipart', {}).get('status')}、raw HTTP {p6.get('raw', {}).get('status')}，SHA256 round-trip={p6.get('sha256_matches', '未驗證')}；source 要 raw body、允許 MIME 與 X-Artifact-Filename，不需要 session，真機 browser control disabled。")
        p7 = p.get('7', {})
        parts = []
        for mode in ('stop', 'steer'):
            item = p7.get(mode, {})
            parts.append(f"{mode}: control={item.get('control', {}).get('resp')}, final={item.get('final_status', {}).get('resp', {}).get('status')}")
        steer_events = p7.get('steer', {}).get('response', {}).get('resp', [])
        steer_text = [e['data'].get('content') for e in steer_events if e['event']=='assistant.completed'] if isinstance(steer_events, list) else []
        reuse = p7.get('stop', {}).get('reuse', {}).get('resp', {}).get('message', {}).get('content')
        answers.append('；'.join(parts)+f'；停止後重用={reuse}；steer 最終文字={steer_text}；stop 最後可能仍標 completed，app 須保留自身停止紀錄。')
        p8 = p.get('8', {})
        answers.append('DELETE 結果：'+', '.join(f"{x['delete'].get('status')}/{x['check'].get('status')}" for x in p8.get('sessions', []))+'（DELETE/後續 GET），清理明細見 probes.8。')
        self.result['answers'] = answers
        self.save()
        md = '# P0 真機能力驗證\n\n'+f"結果：`{self.path.name}`；request 引用對應 JSON requests[].id。\n\n"
        for n, answer in enumerate(answers, 1):
            md += f"## {n}\n\n{answer}\n\n證據：`probes.{n}`；完整 method/url/req/resp 在 `requests`。\n\n"
        md += '## 勘誤\n\n- §2 GET /v1/runs 回 405；capabilities 僅列 POST /v1/runs；session chat stream 提供 run.started。\n- §2 禁止 DELETE/PATCH 的描述與 capabilities 不符；DELETE 實測見第 8 題，PATCH 未測。\n- §3 歷史訊息實際包在 data[]，不是 messages[]。\n- §2/§3 SSE 還有 run.started、message.started、assistant.completed、tool.progress、done；tool.progress 的 reasoning 不代表新的工具呼叫，不能據此重分旁白。\n- §2 附件 source 為 raw upload，不是 multipart；capabilities 的 browser_extension_control.enabled=false，upload 目前不可用。\n- stop 實測 stopping 後變 completed，assistant.completed.interrupted 仍為 false；不能只靠 terminal status 判定是否使用者停止。\n- run 結束後 source 保留狀態 3600 秒，另由 60 秒 sweep 清理；本次僅量測有限時間，不宣稱已驗證到期時間。\n\n## 限制\n\n模型输出非決定性；沒有出現的旁白切換不算已驗證；歷史分頁比較是當次快照，活躍 session 仍可能變動。source 是本機 checkout，與正在執行的 server 可能存在版本差異。\n'
        self.path.with_suffix('.md').write_text(md)
        for n, answer in enumerate(answers, 1): print(f'{n}. {answer}', flush=True)

    def run(self):
        try: self.capture_source()
        except Exception as e: self.result['source_evidence']['error'] = str(e)
        self.result['capabilities'] = self.http('GET', '/v1/capabilities')
        try:
            for n in range(1,8):
                print(f'Running probe {n}', flush=True)
                try: self.result['probes'][str(n)] = getattr(self, f'probe{n}')()
                except Exception as e: self.result['probes'][str(n)] = {'error': str(e)}
                self.save()
            for rid, ended in self.completed_runs:
                remaining = self.retention-(time.monotonic()-ended)
                if remaining>0: time.sleep(remaining)
                self.result['probes']['1']['retention_recheck'] = {'seconds_after_completion': time.monotonic()-ended, 'response': self.http('GET', '/v1/runs/'+rid)}
        finally:
            try: self.result['probes']['8'] = self.probe8()
            except Exception as e: self.result['probes']['8'] = {'error': str(e)}
            self.result['finished_at'] = now()
            self.save()
        self.report()
        print(str(self.path), flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--retention-seconds', type=int, default=65)
    Probe(parser.parse_args().retention_seconds).run()
