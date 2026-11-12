#!/usr/bin/env python3
"""STATION-LANE D3：判定表與狀態轉移的回歸測試，外加 D1 探針的端到端測試。

    cd ~/hermes-app && .venv-web/bin/python3 -m unittest discover -s web/ops -p 'test_*.py'

紅過的理由：判定表、探針與狀態檔行為在這些符號出現之前不存在，import
就會失敗。
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import station_watch_lib as swl  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[2]
PROBE = REPO / "web" / "ops" / "station-probe.py"


class VerdictTable(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(
            swl.verdict(True, True, True, "probe", 5), "OK")

    def test_serve_beats_everything(self):
        self.assertEqual(
            swl.verdict(False, True, True, "probe", 5), "SERVE")
        # 本地壞優先於探針來源問題（工單明定的案例）
        self.assertEqual(
            swl.verdict(False, True, False, "ssh-fail", None), "SERVE")

    def test_upstream(self):
        self.assertEqual(
            swl.verdict(True, False, True, "probe", 5), "UPSTREAM")
        # gateway 壞優先於 ssh-fail（工單沒定義，計畫拍板：照表序 UPSTREAM）
        self.assertEqual(
            swl.verdict(True, False, False, "ssh-fail", None), "UPSTREAM")

    def test_tailnet(self):
        self.assertEqual(
            swl.verdict(True, True, False, "probe", 5), "TAILNET")

    def test_probe_stale_ssh_fail(self):
        self.assertEqual(
            swl.verdict(True, True, False, "ssh-fail", None), "PROBE-STALE")

    def test_probe_stale_age(self):
        self.assertEqual(
            swl.verdict(True, True, True, "probe", 181), "PROBE-STALE")
        # 邊界：恰好 180 秒不算過舊
        self.assertEqual(
            swl.verdict(True, True, True, "probe", 180), "OK")


class ParseTsnet(unittest.TestCase):
    def test_rc_nonzero_is_ssh_fail(self):
        self.assertEqual(swl.parse_tsnet(1, '{"ts": 1, "ok": true}', 10),
                         (False, "ssh-fail", None, None))

    def test_empty_line_is_ssh_fail(self):
        self.assertEqual(swl.parse_tsnet(0, "", 10),
                         (False, "ssh-fail", None, None))

    def test_garbage_line_is_ssh_fail(self):
        # 驗收閘 4 原樣跑 bash -c 時 brace expansion 會產出這種非 JSON 字串
        self.assertEqual(swl.parse_tsnet(0, "ts:1 ok:true", 10),
                         (False, "ssh-fail", None, None))

    def test_fresh_ok_line(self):
        line = json.dumps({"ts": 90, "ok": True, "err": None})
        self.assertEqual(swl.parse_tsnet(0, line, 100),
                         (True, "probe", 10, None))

    def test_ts_not_int_is_ssh_fail(self):
        self.assertEqual(swl.parse_tsnet(0, '{"ts": "90", "ok": true}', 100),
                         (False, "ssh-fail", None, None))


def _peer(dns, host, active, cur_addr, relay):
    return {"DNSName": dns, "HostName": host, "Active": active,
            "CurAddr": cur_addr, "Relay": relay}


TWO_PEERS = json.dumps({"Peer": {
    "a": _peer("zaber-2.tail592d86.ts.net.", "zaber", True, "", "hkg"),
    "b": _peer("zaber.tail592d86.ts.net.", "zaber", False, "", "tok"),
}})


class PeerState(unittest.TestCase):
    def test_dns_name_match_relay(self):
        # 兩台 HostName 都是 zaber：只能靠 DNSName 挑對台；CurAddr 空＝走中繼
        self.assertEqual(swl.peer_state(TWO_PEERS), ("relay", "hkg"))

    def test_direct(self):
        text = json.dumps({"Peer": {
            "a": _peer(swl.ZABER2_DNS, "zaber", True, "100.82.116.119", "hkg")}})
        self.assertEqual(swl.peer_state(text), ("direct", "hkg"))

    def test_missing_and_garbage(self):
        self.assertEqual(swl.peer_state('{"Peer": {}}'), ("missing", "-"))
        self.assertEqual(swl.peer_state("not json"), ("missing", "-"))


class Transition(unittest.TestCase):
    def test_new_alert(self):
        self.assertEqual(swl.transition("", "TAILNET"), ("alert", "TAILNET"))

    def test_repeat_silence(self):
        self.assertEqual(swl.transition("TAILNET", "TAILNET"),
                         ("none", None))

    def test_stale_touches_nothing(self):
        # TAILNET→PROBE-STALE→TAILNET 不重發告警的關鍵：STALE 不動狀態檔
        self.assertEqual(swl.transition("TAILNET", "PROBE-STALE"),
                         ("none", None))

    def test_recover_clears(self):
        self.assertEqual(swl.transition("TAILNET", "OK"), ("recover", ""))

    def test_ok_from_empty_is_silent(self):
        self.assertEqual(swl.transition("", "OK"), ("none", None))


class _Handler200(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"version":"test"}')

    def log_message(self, *args):
        pass


class ProbeEndToEnd(unittest.TestCase):
    def _run(self, env):
        full = dict(os.environ, **env)
        proc = subprocess.run(
            [sys.executable, str(PROBE)], env=full,
            capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def test_ok_and_six_keys(self):
        srv = HTTPServer(("127.0.0.1", 0), _Handler200)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                log = os.path.join(tmp, "probe.jsonl")
                out = self._run({"STATION_PROBE_URL":
                                 f"http://127.0.0.1:{srv.server_port}/x",
                                 "STATION_PROBE_LOG": log})
                rec = json.loads(out)
                self.assertIs(rec["ok"], True, rec)
                self.assertEqual(rec["status"], 200)
                self.assertLessEqual(
                    {"ts", "url", "ok", "status", "sec", "err"}, set(rec))
                with open(log, encoding="utf-8") as fh:
                    self.assertEqual(json.loads(fh.read().strip()), rec)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_closed_port_is_ok_false_rc_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "probe.jsonl")
            out = self._run({"STATION_PROBE_URL":
                             "http://127.0.0.1:1/unreachable",
                             "STATION_PROBE_LOG": log})
            rec = json.loads(out)
            self.assertIs(rec["ok"], False, rec)
            self.assertIsNotNone(rec["err"])

    def test_rotation_produces_dot1(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "probe.jsonl")
            env = {"STATION_PROBE_URL": "http://127.0.0.1:1/x",
                   "STATION_PROBE_LOG": log,
                   "STATION_PROBE_MAX_BYTES": "1"}
            self._run(env)
            self.assertFalse(os.path.exists(log + ".1"))
            self._run(env)  # 第一行已超過 1 byte → 輪替
            self.assertTrue(os.path.exists(log + ".1"))
            with open(log, encoding="utf-8") as fh:
                json.loads(fh.read().strip())  # 新檔仍是合法 JSON 一行


if __name__ == "__main__":
    unittest.main(verbosity=2)
