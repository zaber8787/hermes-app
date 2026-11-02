"""TASK-PROGRESSBRIDGE: cron run records are not listed as app conversations.

Core's real ``GET /api/sessions`` (APIServerAdapter._handle_list_sessions) runs
on a real SessionDB tmp file holding cron rows beside Discord and API rows.
Red: without the unit the cron rows are listed (and take page slots). Green:
the default list drops them in SQL, ``?source=cron`` still lists them, and
``GET /api/sessions/{id}`` still reads one. The unit binds onto subclasses so
the real classes stay untouched.
"""
import asyncio
import json
import pathlib
import shutil
import tempfile
import unittest
from unittest import mock

from aiohttp.test_utils import make_mocked_request

from compat import session_list

from test_crosssource import Tx


def adapter_and_db(tmp):
    from gateway.platforms import api_server
    from hermes_state import SessionDB

    class DB(SessionDB):
        pass

    class Adapter(api_server.APIServerAdapter):
        pass
    db = DB(tmp / "state.db")
    adapter = Adapter.__new__(Adapter)
    adapter._check_auth = lambda request: None

    async def ensure():
        return db
    adapter._ensure_session_db_async = ensure
    return Adapter, DB, adapter, db


def get(adapter, path, handler="_handle_list_sessions", **match):
    request = make_mocked_request("GET", path, match_info=match)
    response = asyncio.run(getattr(adapter, handler)(request))
    return response.status, json.loads(response.body)


class CronLeavesTheList(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.cls, self.db_cls, self.adapter, self.db = adapter_and_db(self.tmp)
        self.db.create_session("discord_thread", "discord", session_key="agent:main:discord:thread:1:1")
        self.db.create_session("api_chat", "api_server")
        # Newest last: unfiltered, the cron rows would fill the top of every latest-first page.
        for n in range(5):
            self.db.create_session(f"cron_job{n}_20261101", "cron")

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def sources(self, path="/api/sessions?limit=500&offset=0&order=latest&include_hidden=true"):
        status, body = get(self.adapter, path)
        self.assertEqual(200, status)
        return sorted(row["source"] for row in body["data"])

    def test_red_without_unit_cron_rows_are_listed(self):
        self.assertEqual(["api_server"] + ["cron"] * 5 + ["discord"], self.sources())

    def test_green_default_list_has_no_cron(self):
        session_list.install(self.cls, self.db_cls, Tx())
        self.assertEqual(["api_server", "discord"], self.sources())

    def test_red_without_unit_cron_rows_take_the_page(self):
        status, body = get(self.adapter, "/api/sessions?limit=2")
        self.assertEqual(["cron", "cron"], [row["source"] for row in body["data"]])

    def test_cron_rows_do_not_take_page_slots(self):
        session_list.install(self.cls, self.db_cls, Tx())
        status, body = get(self.adapter, "/api/sessions?limit=2")
        self.assertEqual(["api_chat", "discord_thread"], sorted(row["id"] for row in body["data"]))

    def test_explicit_source_still_lists_cron(self):
        session_list.install(self.cls, self.db_cls, Tx())
        self.assertEqual(["cron"] * 5, self.sources("/api/sessions?source=cron&limit=200"))

    def test_cron_session_still_reads_by_id(self):
        session_list.install(self.cls, self.db_cls, Tx())
        status, body = get(self.adapter, "/api/sessions/cron_job0_20261101", "_handle_get_session",
                           session_id="cron_job0_20261101")
        self.assertEqual(200, status)
        self.assertEqual(("cron_job0_20261101", "cron"), (body["session"]["id"], body["session"]["source"]))

    def test_other_callers_of_list_sessions_rich_are_untouched(self):
        session_list.install(self.cls, self.db_cls, Tx())
        rows = self.db.list_sessions_rich(limit=50)
        self.assertEqual(5, sum(row["source"] == "cron" for row in rows))

    def test_restore_unbinds(self):
        tx = Tx()
        session_list.install(self.cls, self.db_cls, tx)
        for target, name, old in reversed(tx.changes):
            setattr(target, name, old)
        self.assertIn("cron", self.sources())


class ForeignFields(unittest.TestCase):
    """Real SessionDB rows through core's real handlers: only the wrapper adds these keys."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.cls, self.db_cls, self.adapter, self.db = adapter_and_db(self.tmp)
        self.db.create_session("discord_thread", "discord", session_key="agent:main:discord:thread:1:1")
        self.db.create_session("discord_dm", "discord")
        self.db.create_session("api_chat", "api_server")
        self.db.create_session("room", "bot_room")
        self.db.create_session("tui_chat", "tui")
        self.db.create_session("cron_run", "cron")
        self.db._conn.execute("UPDATE sessions SET thread_id = '1544350912389189704' WHERE id = 'discord_thread'")
        self.db._conn.commit()

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def rows(self):
        status, body = get(self.adapter, "/api/sessions?limit=500&include_hidden=true")
        self.assertEqual(200, status)
        return {row["id"]: row for row in body["data"]}

    def test_red_without_unit_no_row_carries_them(self):
        for row in self.rows().values():
            self.assertNotIn("foreign_source", row)
            self.assertNotIn("thread_id", row)

    def test_foreign_rows_are_marked_and_http_owned_rows_are_not(self):
        session_list.install(self.cls, self.db_cls, Tx())
        rows = self.rows()
        self.assertIs(True, rows["discord_thread"]["foreign_source"])
        self.assertEqual("1544350912389189704", rows["discord_thread"]["thread_id"])
        self.assertIs(True, rows["discord_dm"]["foreign_source"])
        self.assertNotIn("thread_id", rows["discord_dm"])
        self.assertIs(True, rows["tui_chat"]["foreign_source"])
        self.assertNotIn("thread_id", rows["tui_chat"])
        for sid in ("api_chat", "room"):
            self.assertNotIn("foreign_source", rows[sid])
            self.assertNotIn("thread_id", rows[sid])

    def test_core_safe_fields_stay_and_nothing_else_leaks(self):
        session_list.install(self.cls, self.db_cls, Tx())
        row = self.db.get_session("discord_thread")
        wrapped = self.cls._session_response(row)
        plain = self.cls.__mro__[1]._session_response(row)
        extra = {k: v for k, v in wrapped.items() if k not in plain}
        self.assertEqual({"foreign_source": True, "thread_id": "1544350912389189704"}, extra)

    def test_a_cron_row_read_by_id_is_marked(self):
        session_list.install(self.cls, self.db_cls, Tx())
        status, body = get(self.adapter, "/api/sessions/cron_run", "_handle_get_session", session_id="cron_run")
        self.assertEqual(200, status)
        self.assertIs(True, body["session"]["foreign_source"])

    def test_real_transaction_binds_and_restores_a_static(self):
        from compat import compat as c
        tx = c.Transaction()
        session_list.install(self.cls, self.db_cls, tx)
        self.assertIs(True, self.rows()["tui_chat"]["foreign_source"])
        tx.restore()
        self.assertNotIn("foreign_source", self.rows()["tui_chat"])


class Drift(unittest.TestCase):
    def test_response_seam_drift_raises(self):
        from gateway.platforms import api_server
        from hermes_state import SessionDB

        class Adapter(api_server.APIServerAdapter):
            def _session_response(self, session):
                return {}
        with self.assertRaisesRegex(RuntimeError, "_session_response"):
            session_list.check(Adapter, SessionDB)

    def test_real_seams_hold(self):
        from gateway.platforms import api_server
        from hermes_state import SessionDB
        session_list.check(api_server.APIServerAdapter, SessionDB)

    def test_signature_drift_raises(self):
        from gateway.platforms import api_server

        class DB:
            def list_sessions_rich(self, source=None, limit=20):
                return []
        with self.assertRaisesRegex(RuntimeError, "signature changed"):
            session_list.check(api_server.APIServerAdapter, DB)

    def test_handler_drift_raises(self):
        from gateway.platforms import api_server
        from hermes_state import SessionDB
        with mock.patch.object(session_list.inspect, "getsource", lambda f: "async def x(): pass"):
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                session_list.check(api_server.APIServerAdapter, SessionDB)

    def test_compat_skips_the_unit_loudly_on_drift(self):
        # A raising _install_* is reported skipped_incompatible with a warning (compat.register loop);
        # here: the unit's own entry point raises instead of binding anything.
        from compat import compat as c
        holder = type("api", (), {})()
        holder.APIServerAdapter = type("Adapter", (), {})
        tx = Tx()
        with mock.patch.object(c, "api", holder, create=True):
            with self.assertRaises(RuntimeError):
                c._install_session_list(tx)
        self.assertEqual([], tx.changes)

    def test_unit_is_registered_before_crosssource_and_shipped(self):
        from compat import compat as c
        self.assertEqual(["session_list", "crosssource"], list(c.UNITS[-2:]))
        script = (pathlib.Path(session_list.__file__).parent / "install.sh").read_text()
        self.assertIn("session_list.py", script)


if __name__ == "__main__":
    unittest.main()
