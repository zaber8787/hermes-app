"""Run the pytest-style cases with unittest when pytest cannot be installed.

This is an explicit offline adapter, not a replacement pytest installation.
"""
import contextlib
import importlib.util
import inspect
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


class MonkeyPatch:
    def __init__(self):
        self.stack = contextlib.ExitStack()

    def setattr(self, obj, name, value, raising=True):
        self.stack.enter_context(patch.object(obj, name, value, create=not raising))

    def setitem(self, mapping, key, value):
        self.stack.enter_context(patch.dict(mapping, {key: value}))


@contextlib.contextmanager
def raises(exception, match):
    import re
    try:
        yield
    except exception as exc:
        assert re.search(match, str(exc)), str(exc)
    else:
        raise AssertionError(f'Expected {exception}')


adapter = types.ModuleType('pytest')
adapter.fixture = lambda function: function
adapter.raises = raises
adapter.fail = lambda message: (_ for _ in ()).throw(AssertionError(message))
spec = importlib.util.spec_from_file_location('media_cases', Path(__file__).with_name('test_media_persist.py'))
cases = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'pytest': adapter}):
    spec.loader.exec_module(cases)


class MediaPersistTests(unittest.TestCase):
    pass


def make_test(function):
    def run(self):
        with tempfile.TemporaryDirectory(prefix='media-persist-') as directory:
            monkeypatch = MonkeyPatch()
            with monkeypatch.stack:
                values = {'tmp_path': Path(directory), 'monkeypatch': monkeypatch}
                if 'installed' in inspect.signature(function).parameters:
                    fixture = cases.installed(values['tmp_path'], monkeypatch)
                    values['installed'] = next(fixture)
                    self.addCleanup(lambda: next(fixture, None))
                try:
                    function(**{name: values[name] for name in inspect.signature(function).parameters})
                finally:
                    if 'installed' in values:
                        next(fixture, None)
    return run


for name, function in vars(cases).items():
    if name.startswith('test_'):
        setattr(MediaPersistTests, name, make_test(function))

if __name__ == '__main__':
    print('Offline unittest adapter executing pytest-style cases', flush=True)
    unittest.main(verbosity=2)
