"""Opt-in notification watchers must stay bounded across many runs."""

import unittest

from compat import notification_events as events


class WatchBoundTests(unittest.TestCase):
    def test_one_thousand_distinct_runs_do_not_grow_the_registry_without_limit(self):
        reg = {"watchers": {}}
        for i in range(1000):
            events.watch(reg, owner_scope="same-owner", run_id=f"run-{i}", on=True)
        self.assertLessEqual(len(reg["watchers"]), 256)
        self.assertIn(("same-owner", "run-999"), reg["watchers"])
        self.assertNotIn(("same-owner", "run-0"), reg["watchers"])

    def test_rewatch_keeps_recent_opt_in_when_capacity_is_reached(self):
        reg = {"watchers": {}}
        for i in range(256):
            events.watch(reg, owner_scope="owner", run_id=f"run-{i}", on=True)
        events.watch(reg, owner_scope="owner", run_id="run-0", on=True)
        events.watch(reg, owner_scope="owner", run_id="run-256", on=True)
        self.assertIn(("owner", "run-0"), reg["watchers"])
        self.assertNotIn(("owner", "run-1"), reg["watchers"])


if __name__ == "__main__":
    unittest.main()
