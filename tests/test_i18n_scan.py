import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCANNER = Path(__file__).resolve().parent.parent / "tools" / "i18n_scan.py"


def run(root: Path) -> int:
    return subprocess.run(
        [sys.executable, str(SCANNER), "--root", str(root)],
        capture_output=True,
        text=True,
    ).returncode


class ScannerCanary(unittest.TestCase):
    def scan(self, body: str) -> int:
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp) / "app" / "lib"
            lib.mkdir(parents=True)
            (lib / "t.dart").write_text(body, encoding="utf-8")
            return run(Path(tmp) / "app")

    def test_plain_chinese_literal_fails(self):
        self.assertEqual(1, self.scan("const a = Text('中文');\n"))

    def test_chinese_comment_passes(self):
        self.assertEqual(0, self.scan("// 中文說明\nconst a = 'ok';\n"))

    def test_nested_interpolation_fallback_fails(self):
        self.assertEqual(
            1, self.scan("const a = 'x${cond ? '繼續' : y}';\n")
        )

    def test_raw_string_fails(self):
        self.assertEqual(1, self.scan("const a = r'''附件''';\n"))

    def test_escaped_cjk_fails(self):
        self.assertEqual(1, self.scan("const a = '\\u9644件';\n"))

    def test_escaped_cjk_braces_fails(self):
        self.assertEqual(1, self.scan("const a = '\\u{9644}';\n"))

    def test_fullwidth_punctuation_only_is_not_flagged(self):
        self.assertEqual(0, self.scan("const a = '，。！';\n"))

    def test_exact_exempt_literal_passes_distant_label_fails(self):
        body = (
            "// i18n-exempt: protocol\n"
            "const a = '[附件: x]';\n"
            "\n"
            "// unrelated\n"
            "const g = '另一個中文';\n"
        )
        self.assertEqual(1, self.scan(body))
        self.assertEqual(0, self.scan(body.replace("const g", "// const g")))

    def test_broad_stale_exempt_window_does_not_cover(self):
        body = (
            "// i18n-exempt\n"
            "// note\n"
            "// note2\n"
            "const far = '好';\n"
        )
        self.assertEqual(1, self.scan(body))
        body_ok = "// i18n-exempt\nconst a = '附件';\n"
        self.assertEqual(0, self.scan(body_ok))
        too_far = (
            "// i18n-exempt\n"
            "// note\n"
            "// note2\n"
            "const a = '附件';\n"
        )
        self.assertEqual(1, self.scan(too_far))

    def test_symlink_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp) / "app" / "lib"
            lib.mkdir(parents=True)
            (lib / "real.dart").write_text("const a = 'ok';\n", encoding="utf-8")
            try:
                (lib / "link.dart").symlink_to(lib / "real.dart")
            except OSError:
                self.skipTest("symlinks unavailable")
            self.assertEqual(1, run(Path(tmp) / "app"))

    def test_missing_root_is_usage_error(self):
        self.assertEqual(2, run(Path(tempfile.mkdtemp()) / "nope"))

    def test_repo_is_clean(self):
        self.assertEqual(0, run(SCANNER.parent.parent / "app"))


if __name__ == "__main__":
    unittest.main()
