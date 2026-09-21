#!/usr/bin/env python3
"""Contract tests for scripts/runtime_config.py (ENVHYGIENE §7.2).

Every case uses a temp file + explicit environment dict; the real ~/.hermes
environment is NEVER consulted."""
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(
    0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import runtime_config as rc  # noqa: E402


class EnvCase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        self.home.mkdir()

    def env(self, **kw):
        e = {"HOME": str(self.home)}
        e.update(kw)
        return e

    def write(self, path, body):
        path.write_text(body, encoding="utf-8")
        return path


class Selector(EnvCase):
    def test_default(self):
        got = rc.select_env_file(self.env())
        self.assertEqual(got, (self.home / ".hermes" / ".env").resolve())

    def test_override_and_tilde(self):
        got = rc.select_env_file(self.env(HERMES_ENV_FILE="~/my.env"))
        self.assertEqual(got, pathlib.Path(os.path.expanduser("~/my.env")).resolve())

    def test_legacy_alias(self):
        got = rc.select_env_file(self.env(HERMES_WEB_ENV=str(self.tmp / "x.env")))
        self.assertEqual(got, (self.tmp / "x.env").resolve())

    def test_empty_selector_is_unset(self):
        got = rc.select_env_file(self.env(HERMES_ENV_FILE="  "))
        self.assertEqual(got, (self.home / ".hermes" / ".env").resolve())

    def test_conflict_is_fatal(self):
        with self.assertRaises(rc.ConfigError):
            rc.select_env_file(self.env(
                HERMES_ENV_FILE=str(self.tmp / "a.env"),
                HERMES_WEB_ENV=str(self.tmp / "b.env")))

    def test_same_path_both_names_ok(self):
        p = self.tmp / "same.env"
        p.touch()
        got = rc.select_env_file(self.env(
            HERMES_ENV_FILE=str(p), HERMES_WEB_ENV=str(p)))
        self.assertEqual(got, p.resolve())


class Parser(EnvCase):
    def test_full_syntax(self):
        f = self.write(self.tmp / "e", "\n".join([
            "# comment",
            "",
            "export A=1",
            "B = two words  ",
            "C='single # not comment'",
            'D="dq\\ttab"',
            "E=trail # inline comment",
            "F=",
            "OTHER=https://ignored.example",
        ]) + "\n")
        got = rc.parse_env_file(f, {"A", "B", "C", "D", "E", "F"})
        self.assertEqual(got, {"A": "1", "B": "two words",
                               "C": "single # not comment",
                               "D": "dq\\ttab",  # quotes pair off, content literal
                               "E": "trail", "F": ""})
        self.assertNotIn("OTHER", got, "allowlist names only")

    def test_duplicate_is_error(self):
        f = self.write(self.tmp / "e", "A=1\nA=2\n")
        with self.assertRaises(rc.ConfigError):
            rc.parse_env_file(f, {"A"})

    def test_unbalanced_quote_is_error(self):
        f = self.write(self.tmp / "e", 'A="open\nnext=1\n')
        with self.assertRaises(rc.ConfigError):
            rc.parse_env_file(f, {"A"})

    def test_no_expansion_ever(self):
        f = self.write(self.tmp / "e", "A=$HOME\nB=$(touch x)\nC=`id`\n")
        got = rc.parse_env_file(f, {"A", "B", "C"})
        self.assertEqual(got, {"A": "$HOME", "B": "$(touch x)", "C": "`id`"})


class Resolution(EnvCase):
    def test_process_env_wins(self):
        f = self.write(self.tmp / "e", "HERMES_WEB_PORT=1111\n")
        r = rc.Resolver(self.env(HERMES_WEB_PORT="2222",
                                HERMES_ENV_FILE=str(f)))
        self.assertEqual(r.resolve("HERMES_WEB_PORT", default="8700"), "2222")

    def test_file_then_default(self):
        f = self.write(self.tmp / "e", "HERMES_WEB_PORT=1111\n")
        r = rc.Resolver(self.env(HERMES_ENV_FILE=str(f)))
        self.assertEqual(r.resolve("HERMES_WEB_PORT", default="8700"), "1111")
        self.assertEqual(r.resolve("HERMES_WEB_HOST", default="127.0.0.1"),
                         "127.0.0.1")

    def test_empty_required_illegal(self):
        f = self.write(self.tmp / "e", "HERMES_LIVE_BASE_URL=\n")
        r = rc.Resolver(self.env(HERMES_ENV_FILE=str(f)))
        with self.assertRaises(rc.ConfigError):
            r.resolve("HERMES_LIVE_BASE_URL", required=True)

    def test_missing_file_default_selector_ok(self):
        r = rc.Resolver(self.env())  # nothing under fake HOME
        self.assertEqual(r.resolve("HERMES_WEB_PORT", default="8700"), "8700")

    def test_missing_file_explicit_selector_fails(self):
        with self.assertRaises(rc.ConfigError):
            rc.Resolver(self.env(HERMES_ENV_FILE=str(self.tmp / "gone.env")))

    def test_key_is_file_only_and_reread(self):
        f = self.write(self.tmp / "e", 'API_SERVER_KEY="k1"\n')
        r = rc.Resolver(self.env(HERMES_ENV_FILE=str(f), API_SERVER_KEY="proc"))
        self.assertEqual(rc.read_key(f), "k1", "quotes must agree with Dart")
        self.assertFalse(r.resolve("API_SERVER_KEY", default="") == "proc",
                         "process env must not override the key path")
        f.write_text('API_SERVER_KEY="k2"\n', encoding="utf-8")
        self.assertEqual(rc.read_key(f), "k2", "rotation re-read")

    def test_key_present_bool_only(self):
        f = self.write(self.tmp / "e", "API_SERVER_KEY=secret-value\n")
        r = rc.Resolver(self.env(HERMES_ENV_FILE=str(f)))
        self.assertTrue(r.key_present())
        r2 = rc.Resolver(self.env())  # default selector, file absent
        self.assertFalse(r2.key_present())


class Validation(EnvCase):
    def test_normalisation(self):
        self.assertEqual(
            rc.validate_url("https://s.example.com:8443/", name="u"),
            "https://s.example.com:8443")

    def test_rejects(self):
        for bad in ["", "ftp://x", "http://", "http://u:p@h", "http://h/?a=1",
                    "http://h#f", "not a url"]:
            with self.assertRaises(rc.ConfigError, msg=bad):
                rc.validate_url(bad, name="u")

    def test_origin_only_for_upstream(self):
        rc.validate_url("http://h:8642/x", name="u", allow_path=True)
        with self.assertRaises(rc.ConfigError):
            rc.validate_url("http://h:8642/x", name="u")

    def test_port_range(self):
        with self.assertRaises(rc.ConfigError):
            rc.validate_url("http://h:99999", name="u")


if __name__ == "__main__":
    unittest.main()
