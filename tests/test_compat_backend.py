"""TASK-COMPATDRIFT: the executing core must be a reviewed compat backend.

The probe half runs outside the gateway process: it reads the core's current
source (``inspect.getsource`` / the same disk fallback compat uses) and fails
with the live digests and the missing table entries whenever the core drifted
from every reviewed backend, so an upgrade shows up here instead of as a
silent ``backend=unknown`` in agent.log.

The regression half pins the behavior this task changed: a live-source match
selects its backend, the vnew chat-stream copy flushes its event queue, the
renamed skills seam still installs, and steer_inbox stays fail-closed on vnew.
"""
import ast
import asyncio
import hashlib
import inspect
import types
import unittest
from unittest import mock

from compat import compat as c


def _diff_report(digests, tables):
    lines = [f"live digests: {digests}"]
    for name, table in tables.items():
        missing = sorted(k for k, v in table.items() if digests.get(k) != v)
        lines.append(f"  {name}: mismatched {missing}")
    return "\n".join(lines)


class LiveBackendProbe(unittest.TestCase):
    def test_current_core_is_a_reviewed_backend(self):
        from gateway.platforms import api_server as api
        cls = api.APIServerAdapter
        live = {n: hashlib.sha256(inspect.getsource(
            inspect.unwrap(getattr(cls, n))).encode()).hexdigest() for n in c.BASE_FINGERPRINTS}
        disk = c._disk_digests(cls) or {}
        backend = c._detect_backend(cls)
        self.assertIn(backend, c.TARGET_LIKE, "no reviewed backend for the current core\n"
                      + _diff_report(live, c.BACKENDS) + "\n" + _diff_report(disk, c.BACKENDS))

    def test_current_core_private_seams_are_reviewed(self):
        from gateway.platforms import api_server as api
        backend = c._detect_backend(api.APIServerAdapter)
        from cron import scheduler_delivery as sd
        from hermes_state import SessionDB
        from hermes_state_messages import SessionMessagesMixin
        from agent import agent_runtime_helpers as arh
        owners = {
            "_live_route_metadata": sd, "_standalone_send": sd, "_target_mirror_eligible": sd,
            "_deliver_result": sd, "_execute_write": SessionDB, "_read_all": SessionDB,
            "_session_turn_lease_key": SessionDB, "_merge_consecutive_users": arh,
        }
        tables = {
            "CRON": {"target": c.CRON_TARGET_FINGERPRINTS, "v022": c.CRON_V022_FINGERPRINTS,
                     "vnew": c.CRON_VNEW_FINGERPRINTS},
            "WAKE": {"target": c.WAKE_TARGET_FINGERPRINTS, "v022": c.WAKE_V022_FINGERPRINTS,
                     "vnew": c.WAKE_VNEW_FINGERPRINTS},
            "MERGE": {"target": c.MERGE_TARGET_FINGERPRINTS, "v022": c.MERGE_V022_FINGERPRINTS,
                      "vnew": c.MERGE_VNEW_FINGERPRINTS},
        }
        problems = []
        for seam, by_backend in tables.items():
            table = by_backend.get(backend)
            if table is None:
                problems.append(f"{seam}: no table for backend {backend!r}")
                continue
            for name, expected in table.items():
                owner = owners.get(name, SessionMessagesMixin)
                actual = hashlib.sha256(inspect.getsource(
                    inspect.unwrap(getattr(owner, name))).encode()).hexdigest()
                if actual != expected:
                    problems.append(f"{seam} {name}: live {actual} != reviewed {expected}")
        self.assertEqual(problems, [], "\n".join(problems))


class DetectBackend(unittest.TestCase):
    def test_live_source_match_selects_the_backend(self):
        # Red before the fix: a live (non-disk) match fell through to None.
        class Fake:
            def _handle_artifact_upload(self):
                return 1

            def _handle_session_chat_stream(self):
                return 2

            def _run_agent(self):
                return 3
        table = {n: hashlib.sha256(inspect.getsource(getattr(Fake, n)).encode()).hexdigest()
                 for n in c.BASE_FINGERPRINTS}
        with mock.patch.dict(c.BACKENDS, {"fake": table}):
            self.assertEqual(c._detect_backend(Fake), "fake")

    def test_unknown_source_stays_none(self):
        class Fake:
            def _handle_artifact_upload(self):
                return 1

            def _handle_session_chat_stream(self):
                return 2

            def _run_agent(self):
                return 3
        self.assertIsNone(c._detect_backend(Fake))


class SessionStreamFlush(unittest.TestCase):
    def test_events_flush_awaits_queue_flush_and_skips_old_queues(self):
        calls = []

        class NewQueue:
            async def flush(self):
                calls.append("flush")
        asyncio.run(c._events_flush(NewQueue()))
        asyncio.run(c._events_flush(object()))  # target/v022 queue: no flush attribute
        self.assertEqual(calls, ["flush"])

    def test_copy_flushes_after_run_agent_and_before_done(self):
        # Mirrors the two upstream bf0203a794 call sites inside _run_and_signal.
        tree = ast.parse(inspect.getsource(c._session_stream_target))
        inner = next(n for n in ast.walk(tree)
                     if isinstance(n, ast.AsyncFunctionDef) and n.name == "_run_and_signal")
        body = inner.body[0]  # the try statement
        src = [ast.unparse(s) for s in body.body]
        agent_at = next(i for i, s in enumerate(src) if "self._run_agent(" in s)
        self.assertEqual(src[agent_at + 1], "await _events_flush(events)")
        final = [ast.unparse(s) for s in body.finalbody]
        done_at = next(i for i, s in enumerate(final) if "'done'" in s)
        self.assertEqual(final[done_at - 1], "await _events_flush(events)")


class Tx:
    def __init__(self):
        self.sets = []
        self.cleanups = []

    def set(self, target, name, value, **_):
        self.sets.append((target, name))
        setattr(target, name, value)


class SkillsRename(unittest.TestCase):
    def test_renamed_find_all_skills_is_wrapped(self):
        # Red before the fix: AttributeError on _find_all_skills.
        mod = types.ModuleType("tools.skills_tool")
        seen = []

        def find_all_skills(*, skip_disabled=False):
            seen.append(skip_disabled)
            return []
        mod.find_all_skills = find_all_skills
        tools = types.ModuleType("tools")
        tools.skills_tool = mod
        with mock.patch.dict("sys.modules", {"tools": tools, "tools.skills_tool": mod}):
            tx = Tx()
            c._install_skills(tx)
            self.assertEqual(tx.sets, [(mod, "find_all_skills")])
            # /v1/skills on bf0203a794 still passes include_editorial=True.
            self.assertEqual(mod.find_all_skills(skip_disabled=False, include_editorial=True), [])
        self.assertEqual(seen, [False])


class SteerInboxFailClosed(unittest.TestCase):
    def test_vnew_refuses_before_any_binding(self):
        from gateway.platforms import api_server
        tx = Tx()
        with mock.patch.object(c, "_BACKEND", "vnew"), \
                mock.patch.object(c, "api", api_server, create=True):
            with self.assertRaisesRegex(RuntimeError, "session_authority"):
                c._install_steer_inbox(tx)
        self.assertEqual(tx.sets, [])


if __name__ == "__main__":
    unittest.main()
