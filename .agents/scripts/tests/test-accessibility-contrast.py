# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the public contrast CLI, including rounded-up failing ratios."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "accessibility-helper.sh"
PLAYWRIGHT_CONTRAST = HELPER.parent / "accessibility/playwright-contrast.mjs"


class ContrastTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", Path.home() / ".aidevops/.agent-workspace/tmp"))
        root.mkdir(parents=True, exist_ok=True)
        self.home = tempfile.TemporaryDirectory(prefix="contrast-test-", dir=root)
        self.addCleanup(self.home.cleanup)

    def run_cli(self, *args):
        return subprocess.run(
            ["bash", str(HELPER), *args],
            env={
                **os.environ,
                "HOME": self.home.name,
                "LC_ALL": "C",
                "JSONC_DEFAULTS": str(HELPER.parent.parent / "configs/aidevops.defaults.jsonc"),
            },
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def test_contrast_and_thresholds(self):
        # Ratios round for display only: 4.4975956604 and 2.9953461357 fail.
        cases = (
            ("#000", "#FFF", 0, "21.00", ("PASS", "PASS", "PASS", "PASS")),
            ("#FFF", "#000", 0, "21.00", ("PASS", "PASS", "PASS", "PASS")),
            ("#fff", "#ffffff", 1, "1.00", ("FAIL", "FAIL", "FAIL", "FAIL")),
            ("#767676", "#fff", 0, "4.54", ("PASS", "PASS", "FAIL", "PASS")),
            ("#777777", "#fff", 1, "4.48", ("FAIL", "PASS", "FAIL", "FAIL")),
            ("#6e7978", "#fff", 1, "4.50", ("FAIL", "PASS", "FAIL", "FAIL")),
            ("#959595", "#fff", 1, "3.00", ("FAIL", "FAIL", "FAIL", "FAIL")),
        )
        for fg, bg, status, ratio, decisions in cases:
            with self.subTest(fg=fg, bg=bg):
                result = self.run_cli("contrast", fg, bg)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(f"Ratio: {ratio}:1", result.stdout)
                labels = ("AA  Normal", "AA  Large", "AAA Normal", "AAA Large")
                for label, decision in zip(labels, decisions):
                    self.assertRegex(result.stdout, rf"WCAG {label} text.*: {decision}")

    def test_invalid_inputs(self):
        # Failures must propagate from both the first and second dispatch groups.
        cases = (("audit",), ("contrast", "#fff"), ("contrast", "#zzzzzz", "#fff"))
        for args in cases:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 1)
                self.assertTrue(result.stdout or result.stderr)
                self.assertNotIn("PASS", result.stdout)

    def test_help_and_unknown_dispatch(self):
        help_result = self.run_cli("help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("contrast", help_result.stdout)
        self.assertEqual(self.run_cli("unknown-command").returncode, 1)

    def test_playwright_extractor_runs_after_navigation_without_global_binding(self):
        module_path = Path(self.home.name) / "fake-playwright.mjs"
        module_path.write_text(
            """
const document = { fonts: { ready: Promise.resolve() }, querySelectorAll: () => [] };
const page = {
  goto: async () => {},
  waitForLoadState: async () => {},
  evaluate: async (value) => {
    globalThis.document = document;
    globalThis.requestAnimationFrame = (callback) => { callback(); return 1; };
    globalThis.cancelAnimationFrame = () => {};
    if (typeof value === 'function') return value();
    return eval(value);
  },
};
export const chromium = {
  launch: async () => ({
    newContext: async () => ({ newPage: async () => page }),
    close: async () => {},
  }),
};
""",
            encoding="utf-8",
        )
        result = subprocess.run(
            ["node", str(PLAYWRIGHT_CONTRAST), "https://example.invalid", "--format", "summary"],
            env={**os.environ, "AIDEVOPS_PLAYWRIGHT_MODULE": str(module_path)},
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Elements analysed: 0", result.stdout)
        self.assertNotIn("ReferenceError", result.stderr)


if __name__ == "__main__":
    unittest.main()
