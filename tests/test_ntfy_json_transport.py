"""JSON transport regression: the hub rejects a STRING priority (400) —
the ledger publish path must send an integer (01413 ntfy outage)."""
import io, json, unittest, urllib.request, pathlib, sys
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "compat"))
import ntfy_notify


class JsonPriorityShape(unittest.TestCase):
    def _capture(self, priority):
        captured = {}

        class Resp(io.BytesIO):
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["body"] = json.loads(req.data.decode())
            return Resp(b"{}")

        with mock.patch.object(urllib.request, "urlopen", fake_urlopen):
            ntfy_notify._send_json(("http://hub", "topic", "t", "m", priority,
                                    ["done"], None, None))
        return captured

    def test_default_is_integer(self):
        cap = self._capture("default")
        self.assertIsInstance(cap["body"]["priority"], int,
                              "JSON body priority must be an int; strings 400 at the hub")
        self.assertEqual(cap["body"]["priority"], 3)

    def test_high_is_integer(self):
        cap = self._capture("high")
        self.assertIsInstance(cap["body"]["priority"], int)
        self.assertEqual(cap["body"]["priority"], 4)


if __name__ == "__main__":
    unittest.main()
