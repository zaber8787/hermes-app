#!/usr/bin/env python3
"""Regression canaries for the hygiene gate (PUBLIC-AUDIT §3).

Each case reproduces a shape that the pre-fix gate passed as CLEAN and
asserts the staged directory now FAILS with the expected rule id. The
canary literals are split across adjacent string pieces on purpose, so
this file itself stays CLEAN under `hygiene_gate.py --tracked`; the
assembled runtime strings are invented synthetic values, never real
operator data. Run: python3 tools/test_hygiene_gate.py
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "tools" / "hygiene_gate.py"

# --- canaries (invented; split so the source text never matches itself) ---
CONTACT = ("Contact: Avery Example <avery" "@" "example.com>"
           ">\nPhone: " + "+1" "-202" "-555" "-0147"
           + "\nOwner: 合成擁有者標記\n")
CRED = ("API_SERVER_" "KEY=" "syntheticAuditCred" "ential7Qx9Lm2" "\n")
PATHS = ("/home/" "audit-person/private-note.txt"
         "\nC:\\Users\\" "Victim\\note.txt"
         "\nDiscord channel: " "12345678901234" "5678" "\n")
CLEAN_BODY = "\n".join([
    "Server: http://example.com/status  home dir /home/user/x",
    "example windows path C:\\Users\\me\\x and C:\\Users\\name\\x",
    "API_SERVER_KEY=",
    "call +60, arithmetic 200+200, version 0.2.2+4",
    "plain id 1234567890123456, epoch 1757000000",
]) + "\n"


def run_gate(args):
    return subprocess.run([sys.executable, str(GATE)] + args,
                          capture_output=True, text=True)


class GateCanaryCase(unittest.TestCase):
    def setUp(self):
        self.tmp = []

    def tearDown(self):
        for d in self.tmp:
            shutil.rmtree(d, ignore_errors=True)

    def stage(self, files):
        d = pathlib.Path(tempfile.mkdtemp())
        self.tmp.append(d)
        for rel, body in files.items():
            p = d / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body, encoding="utf-8")
        return d

    def assert_fail(self, stage, *rule_ids):
        r = run_gate(["--export", str(stage)])
        self.assertEqual(r.returncode, 1,
                         f"expected FAIL, got rc={r.returncode}\n{r.stdout}")
        for rid in rule_ids:
            self.assertIn(rid, r.stdout, f"{rid} missing in:\n{r.stdout}")

    def assert_clean(self, stage):
        r = run_gate(["--export", str(stage)])
        self.assertEqual(r.returncode, 0, f"expected CLEAN:\n{r.stdout}")

    # §3 case 1: contact/identity canary must now FAIL
    def test_contact_identity(self):
        self.assert_fail(self.stage({"contact.txt": CONTACT}),
                         "email-shape", "phone-shape")

    # §3 case 2: nonempty credential assignment must FAIL
    def test_credential_assignment(self):
        self.assert_fail(self.stage({"config.env": CRED}),
                         "credential-assignment")

    # §3 case 3: concrete home path, windows user path, labelled platform id
    def test_paths_and_platform_ids(self):
        self.assert_fail(self.stage({"paths.txt": PATHS}),
                         "concrete-home-user",
                         "concrete-windows-user-path",
                         "platform-id-labelled")

    # path policy: directory COMPONENTS are scanned, not just basenames
    def test_path_components_scanned(self):
        self.assert_fail(self.stage({"home/audit-person/notes.txt": "hi\n"}),
                         "concrete-home-user")

    # policy basics kept from the original gate
    def test_symlink_and_git_metadata(self):
        d = self.stage({"a.txt": "hello\n"})
        (d / "link.txt").symlink_to("a.txt")
        (d / ".git").mkdir()
        self.assert_fail(d, "symlink", "git-metadata")

    # generic examples, empty assignments and hashes-only shapes stay CLEAN
    def test_clean_control(self):
        self.assert_clean(self.stage({
            "docs/notes.md": CLEAN_BODY,
            "config/env": CLEAN_BODY,
        }))

    # the tracked repository itself must remain CLEAN
    def test_repo_tracked_clean(self):
        r = run_gate(["--tracked"])
        self.assertEqual(r.returncode, 0, f"tracked tree not clean:\n{r.stdout}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
