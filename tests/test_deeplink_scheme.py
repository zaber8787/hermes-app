"""TASK-DEEPLINKFIX R2/R4: ntfy click targets switch from the https entry to
the hermes:// custom scheme ONLY behind deeplink_scheme_enabled (default
false = today's https click, byte for byte). The mapping keeps path, query
and fragment verbatim, and the body keeps the full https URL as a manual
fallback when the scheme has no handler."""
import pathlib, sys, types, unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "compat"))
import notification_events
import ntfy_notify

HTTPS = "https://bot.example.ts.net/#/chat?session=s%2F1&run=r9&event=e7&request=q3"


class SchemeLinkMapping(unittest.TestCase):
    def test_canonical_run_link_keeps_query_and_fragment(self):
        self.assertEqual(
            notification_events.scheme_link(HTTPS),
            "hermes://link/#/chat?session=s%2F1&run=r9&event=e7&request=q3")

    def test_sub_path_entry_and_real_query_survive(self):
        self.assertEqual(
            notification_events.scheme_link("https://h/hermes/?a=1&b=%20#/chat?session=x"),
            "hermes://link/hermes/?a=1&b=%20#/chat?session=x")

    def test_bare_host_maps_to_root_path(self):
        self.assertEqual(notification_events.scheme_link("https://h"), "hermes://link/")

    def test_non_https_is_never_rewritten(self):
        for url in ("http://h/#/chat?session=x", "hermes://link/#/chat?session=x",
                    "", None, "not a url"):
            self.assertIsNone(notification_events.scheme_link(url), url)


class ConfigSwitch(unittest.TestCase):
    def _enabled_with(self, block):
        cfg = types.ModuleType("hermes_cli.config")
        cfg.get_config_path = lambda: __file__  # any readable file
        utils = types.ModuleType("utils")
        utils.fast_safe_load = lambda _h: {"app_compat": {"notification_events": block}}
        with mock.patch.dict(sys.modules, {"hermes_cli": types.ModuleType("hermes_cli"),
                                           "hermes_cli.config": cfg, "utils": utils}):
            return notification_events.deeplink_scheme_enabled()

    def test_default_is_off(self):
        self.assertFalse(self._enabled_with({"click_base": "https://h"}))

    def test_only_literal_true_turns_it_on(self):
        self.assertTrue(self._enabled_with({"deeplink_scheme_enabled": True}))
        for value in (False, "true", 1, None):
            self.assertFalse(self._enabled_with({"deeplink_scheme_enabled": value}), value)

    def test_unreadable_config_is_off(self):
        with mock.patch.dict(sys.modules, {"hermes_cli.config": None}):
            self.assertFalse(notification_events.deeplink_scheme_enabled())


class PublishJsonClick(unittest.TestCase):
    def _publish(self, enabled, click=HTTPS, message="Open the Hermes app for details."):
        jobs = []
        with mock.patch.object(notification_events, "deeplink_scheme_enabled",
                               lambda: enabled), \
             mock.patch.object(ntfy_notify, "_ensure_worker", lambda: None), \
             mock.patch.object(ntfy_notify._jobs, "put_nowait", jobs.append):
            self.assertTrue(ntfy_notify.publish_json(
                "http://hub", "topic", "t", message, click=click))
        fields = jobs[0][1]
        return fields[3], fields[7]  # message, click

    def test_switch_off_keeps_https_click_and_body_unchanged(self):
        message, click = self._publish(False)
        self.assertEqual(click, HTTPS)
        self.assertEqual(message, "Open the Hermes app for details.")

    def test_switch_on_sends_scheme_click_and_https_body_fallback(self):
        message, click = self._publish(True)
        self.assertEqual(click, "hermes://link/#/chat?session=s%2F1&run=r9&event=e7&request=q3")
        self.assertEqual(message, "Open the Hermes app for details.\n" + HTTPS)

    def test_switch_on_without_click_adds_nothing(self):
        message, click = self._publish(True, click=None)
        self.assertIsNone(click)
        self.assertEqual(message, "Open the Hermes app for details.")

    def test_fallback_url_survives_a_body_at_the_byte_cap(self):
        message, _ = self._publish(True, message="中" * 2000)
        self.assertTrue(message.endswith("\n" + HTTPS))
        self.assertLessEqual(len(message.encode("utf-8")), ntfy_notify.BODY_BYTES)

    def test_a_broken_switch_never_breaks_the_push(self):
        def boom():
            raise RuntimeError("config exploded")
        jobs = []
        with mock.patch.object(notification_events, "deeplink_scheme_enabled", boom), \
             mock.patch.object(ntfy_notify, "_ensure_worker", lambda: None), \
             mock.patch.object(ntfy_notify._jobs, "put_nowait", jobs.append):
            ntfy_notify.publish_json("http://hub", "topic", "t", "m", click=HTTPS)
        self.assertEqual(jobs[0][1][7], HTTPS)


if __name__ == "__main__":
    unittest.main()
