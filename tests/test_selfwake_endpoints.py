#!/usr/bin/env python3
"""01413FIX F3: stream-close settlement + listener endpoint parsing
(M4, m7, m8; m9 rides along as the batch-2 config-parsing sibling).
Red at the audit HEAD (repro accepted_zombie, security_checks
endpoint_env / endpoint_ipv6 / deep_link_base), green after F3."""
import asyncio
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
os.environ.setdefault("HERMES_HOME", str(ROOT_DIR))

from compat import auto_wake_store, self_wake, notification_events  # noqa: E402


class SettleUnseen(unittest.TestCase):
    def test_M4_accepted_batch_never_survives_the_intent_as_zombie(self):
        home = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-f3-"))
        c = auto_wake_store.open_ledger(home)
        c.execute("INSERT OR REPLACE INTO wake_batches(batch_id,session_id,"
                  "state,run_id,canonical_input,batch_keys,created_at,"
                  "updated_at) VALUES('zombie','session','accepted','fake-run',"
                  "'x','[]',0,0)")
        c.commit()
        c.close()
        worker = self_wake.SelfWakeWorker(home)
        states = []
        worker._set_items = lambda items, state, **kw: states.append(
            (state, kw.get("detail")))

        async def fail(*args):
            pass
        worker._fail_note = fail

        with patch.object(self_wake, "audit"), \
                patch.object(self_wake, "endpoint",
                             lambda home: (None, "listener disabled")):
            asyncio.run(worker._settle_unseen([], "session", "zombie", "fake-run"))
        row = auto_wake_store.open_ledger(home).execute(
            "SELECT state, terminal_at FROM wake_batches WHERE batch_id='zombie'"
        ).fetchone()
        self.assertIn(row["state"], ("terminal", "uncertain-consumed"),
                      f"M4 red: intent closed but ledger says {row['state']}")
        self.assertIsNotNone(row["terminal_at"], "settlement must timestamp")
        self.assertEqual(states[0][0], "done")

    def test_M4_provable_run_status_closes_as_terminal(self):
        home = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-f3t-"))
        c = auto_wake_store.open_ledger(home)
        c.execute("INSERT OR REPLACE INTO wake_batches(batch_id,session_id,"
                  "state,run_id,canonical_input,batch_keys,created_at,"
                  "updated_at) VALUES('ok','session','accepted','run-9',"
                  "'x','[]',0,0)")
        c.commit()
        c.close()
        worker = self_wake.SelfWakeWorker(home)
        worker._set_items = lambda items, state, **kw: None
        worker._fail_note = None

        async def completed(run_id):
            return "completed"
        worker._run_terminal_once = completed
        with patch.object(self_wake, "audit"):
            asyncio.run(worker._settle_unseen([], "session", "ok", "run-9"))
        row = auto_wake_store.open_ledger(home).execute(
            "SELECT state, terminal_at FROM wake_batches WHERE batch_id='ok'"
        ).fetchone()
        self.assertEqual(row["state"], "terminal")
        self.assertIsNotNone(row["terminal_at"])


class ListenerEndpoint(unittest.TestCase):
    def test_m7_env_file_fallback_matches_dotenv_semantics(self):
        home = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-env-"))
        for text in ("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=FAKE\n",
                     "export API_SERVER_ENABLED=true\nAPI_SERVER_KEY=FAKE\n",
                     "API_SERVER_ENABLED = true\nAPI_SERVER_KEY=FAKE\n",
                     "API_SERVER_ENABLED=true # inline\nAPI_SERVER_KEY=FAKE\n"):
            (home / ".env").write_text(text)
            for name in ("API_SERVER_ENABLED", "API_SERVER_HOST",
                         "API_SERVER_PORT", "API_SERVER_KEY"):
                os.environ.pop(name, None)
            with patch.object(self_wake, "_config", return_value={}):
                got = self_wake.endpoint(home)[0] is not None
            from dotenv import dotenv_values
            want = dotenv_values(home / ".env").get("API_SERVER_ENABLED") == "true"
            self.assertEqual(got, want, f"m7 red for syntax: {text!r}")

    def test_m8_ipv6_loopback_builds_a_valid_URL(self):
        home = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-v6-"))
        cfg = {"gateway": {"api_server": {"enabled": True, "host": "::1",
                                          "port": 8642, "key": "FAKE"}}}
        with patch.object(self_wake, "_config", return_value=cfg), \
                patch.object(self_wake, "_is_own_host", return_value=True):
            base = self_wake.endpoint(home)[0]
        from urllib.parse import urlsplit
        parts = urlsplit(base)
        self.assertEqual(parts.hostname, "::1",
                         f"m8 red: unparsable endpoint {base!r}")
        self.assertEqual(parts.port, 8642)


class DeepLinkBase(unittest.TestCase):
    def test_m9_click_base_drops_credentials_query_and_fragment(self):
        base = notification_events._public_origin(
            "https://audit.invalid/?token=FAKE_CANARY&topic=FAKE_TOPIC#frag")
        self.assertEqual(base, "https://audit.invalid")
        for bad in ("http://audit.invalid",
                    "https://u:pw" + chr(64) + "audit.invalid",
                    "not a url"):
            self.assertEqual(notification_events._public_origin(bad),
                             "https://hermes.invalid")
        with patch.object(notification_events, "_click_base",
                          return_value="https://audit.invalid"):
            url = notification_events.run_link(sid="s", run_id="r")
        self.assertTrue(url.startswith("https://audit.invalid/#/chat?"))


if __name__ == "__main__":
    unittest.main()
