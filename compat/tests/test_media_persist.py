from contextlib import closing
import asyncio
import importlib.util
import json
import sqlite3
import sys
import threading
from pathlib import Path
from types import SimpleNamespace, ModuleType

import pytest
from aiohttp import web

spec = importlib.util.spec_from_file_location('media_compat', Path(__file__).parents[1] / 'compat.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


@pytest.fixture
def installed(tmp_path, monkeypatch):
    monkeypatch.setattr(c, '_MEDIA_ARCHIVE_ROOT', tmp_path / 'archive')
    flag = {'enabled': True}
    config_threads = []
    def enabled():
        config_threads.append(threading.get_ident())
        return flag['enabled']
    monkeypatch.setattr(c, '_media_persist_enabled', enabled)
    monkeypatch.setattr(c, '_BACKEND', 'v022')
    monkeypatch.setattr(c, '_cron_fingerprint', lambda *a: None)
    class Messages:
        def _message_row_params(self, session_id, role, msg, *args, **kwargs):
            return (session_id, role, msg['content'])
    module = ModuleType('hermes_state_messages')
    module.SessionMessagesMixin = Messages
    monkeypatch.setitem(sys.modules, 'hermes_state_messages', module)
    error = web.json_response({'error': {'message': 'Path is not an allowed media file'}}, status=400)
    unauthorized = web.json_response({'error': {'message': 'Unauthorized'}}, status=401)
    class Adapter:
        async def _run_agent(self, *args, **kwargs):
            return ('reply', {'usage': 1})
        def _check_auth(self, request):
            if request.headers.get('Authorization') != 'Bearer secret':
                return unauthorized
        async def _handle_media_download(self, request):
            auth = self._check_auth(request)
            return auth if auth is not None else getattr(self, "download_response", error)
        async def _handle_capabilities(self, request):
            return web.json_response({'features': {}})
    monkeypatch.setattr(c, 'api', SimpleNamespace(APIServerAdapter=Adapter, web=web), raising=False)
    tx = c.Transaction()
    c._install_media_persist(tx)
    yield SimpleNamespace(messages=Messages(), adapter=Adapter(), root=c._MEDIA_ARCHIVE_ROOT,
                          error=error, unauthorized=unauthorized, flag=flag, threads=config_threads)
    tx.restore()


def request(path, auth=True):
    return SimpleNamespace(query={'path': str(path)}, headers={'Authorization': 'Bearer secret'} if auth else {})


def persist(env, source):
    return env.messages._message_row_params('sid', 'assistant', {'content': f'MEDIA:"{source}"'})


def test_mirror_idempotent(installed, tmp_path):
    source = tmp_path / 'image with spaces.png'
    source.write_bytes(b'original image')
    assert persist(installed, source) == ('sid', 'assistant', f'MEDIA:"{source}"')
    with closing(sqlite3.connect(installed.root / 'map.db')) as db:
        first = db.execute('SELECT * FROM media_map').fetchone()
        assert db.execute('PRAGMA journal_mode').fetchone()[0] == 'wal'
    archive = installed.root / first[1]
    assert archive.read_bytes() == b'original image'
    before = archive.stat().st_mtime_ns
    source.write_bytes(b'changed')
    persist(installed, source)
    with closing(sqlite3.connect(installed.root / 'map.db')) as db:
        assert db.execute('SELECT * FROM media_map').fetchall() == [first]
    assert archive.stat().st_mtime_ns == before
    assert archive.read_bytes() == b'original image'


def test_missing_source(installed, tmp_path):
    source = tmp_path / 'gone.png'
    source.write_bytes(b'x')
    source.unlink()
    persist(installed, source)
    with closing(sqlite3.connect(installed.root / 'map.db')) as db:
        assert db.execute('SELECT * FROM media_map').fetchall() == []


def test_download_restore_and_miss(installed, tmp_path):
    source = tmp_path / 'old.png'
    source.write_bytes(b'png bytes')
    persist(installed, source)
    source.unlink()
    async def run():
        response = await installed.adapter._handle_media_download(request(source))
        assert response.status == 200
        assert response.body == b'png bytes'
        assert response.headers['Content-Type'] == 'image/png'
        miss = await installed.adapter._handle_media_download(request(tmp_path / 'unknown.png'))
        assert miss is installed.error
        assert miss.body == installed.error.body
    asyncio.run(run())


def test_download_auth(installed, tmp_path):
    source = tmp_path / 'private.jpg'
    source.write_bytes(b'private')
    persist(installed, source)
    source.unlink()
    response = asyncio.run(installed.adapter._handle_media_download(request(source, auth=False)))
    assert response is installed.unauthorized
    assert response.status == 401


def test_disabled_passthrough(installed, tmp_path):
    source = tmp_path / 'old.png'
    source.write_bytes(b'image')
    persist(installed, source)
    source.unlink()
    installed.flag['enabled'] = False
    response = asyncio.run(installed.adapter._handle_media_download(request(source)))
    assert response is installed.error
    assert response.body == installed.error.body
    fresh = tmp_path / 'new.png'
    fresh.write_bytes(b'new')
    assert persist(installed, fresh) == ('sid', 'assistant', f'MEDIA:"{fresh}"')
    with closing(sqlite3.connect(installed.root / 'map.db')) as db:
        assert db.execute('SELECT orig_path FROM media_map').fetchall() == [(str(source),)]


def test_capability_and_worker_io(installed, tmp_path, monkeypatch):
    main = threading.get_ident()
    seen = []
    original = c._media_mirror
    def mirror(content):
        seen.append(threading.get_ident())
        original(content)
    monkeypatch.setattr(c, '_media_mirror', mirror)
    source = tmp_path / 'async.png'
    source.write_bytes(b'async')
    async def run():
        persist(installed, source)
        assert await installed.adapter._run_agent() == ('reply', {'usage': 1})
        # Drain the submitted mirror using the externally observable completion.
        for _ in range(200):
            if (installed.root / 'map.db').exists():
                with closing(sqlite3.connect(installed.root / 'map.db')) as db:
                    try:
                        if db.execute('SELECT COUNT(*) FROM media_map').fetchone()[0]:
                            break
                    except sqlite3.OperationalError:
                        pass
            await asyncio.sleep(.01)
        else:
            pytest.fail('mirror did not complete')
        for value in (True, False):
            installed.flag['enabled'] = value
            response = await installed.adapter._handle_capabilities(request(source))
            assert json.loads(response.body)['features']['media_persist'] == {
                'enabled': value, 'contract_version': 1}
    asyncio.run(run())
    assert seen and all(t != main for t in seen)
    assert all(t != main for t in installed.threads)


def test_oversized(installed, tmp_path, monkeypatch):
    monkeypatch.setattr(c, '_MEDIA_MAX_BYTES', 3)
    source = tmp_path / 'big.png'
    source.write_bytes(b'1234')
    persist(installed, source)
    with closing(sqlite3.connect(installed.root / 'map.db')) as db:
        assert db.execute('SELECT * FROM media_map').fetchall() == []


def test_unreviewed_backend_rejected(monkeypatch):
    monkeypatch.setattr(c, '_BACKEND', None)
    with pytest.raises(RuntimeError, match='not reviewed'):
        c._cron_fingerprint(SimpleNamespace(), '_message_row_params')


def test_successful_old_history_download_mirrored(installed, tmp_path):
    source = tmp_path / 'historic.png'
    source.write_bytes(b'historic')
    native = web.Response(body=b'historic', content_type='image/png')
    installed.adapter.download_response = native
    response = asyncio.run(installed.adapter._handle_media_download(request(source)))
    assert response is native
    source.unlink()
    del installed.adapter.download_response
    response = asyncio.run(installed.adapter._handle_media_download(request(source)))
    assert response.status == 200
    assert response.body == b'historic'


def test_disabled_success_does_not_archive(installed, tmp_path):
    installed.flag['enabled'] = False
    source = tmp_path / 'fresh.png'
    source.write_bytes(b'image')
    native = web.Response(body=b'image')
    installed.adapter.download_response = native
    assert asyncio.run(installed.adapter._handle_media_download(request(source))) is native
    assert not installed.root.exists()
