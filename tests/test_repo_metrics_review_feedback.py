#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression coverage for repo metrics review-feedback fixes."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from repo_metrics_dependency_common import normalise_dep_name  # noqa: E402
from repo_metrics_dependency_locks import parse_gemfile_lock  # noqa: E402
from repo_metrics_files import should_exclude  # noqa: E402


class RepoMetricsReviewFeedbackTest(unittest.TestCase):
    def test_normalise_dep_name_ignores_pip_editable_flags(self) -> None:
        self.assertEqual(normalise_dep_name("-e ."), "")
        self.assertEqual(normalise_dep_name("-e git+https://example.invalid/pkg.git#egg=pkg"), "")
        self.assertEqual(normalise_dep_name("requests>=2"), "requests")

    def test_should_exclude_matches_basename_globs_in_subdirectories(self) -> None:
        self.assertTrue(should_exclude("src/cache/app.pyc", ["*.pyc"]))
        self.assertTrue(should_exclude("var/log/app.log", ["*.log"]))
        self.assertFalse(should_exclude("src/app.py", ["*.pyc"]))

    def test_parse_gemfile_lock_stops_specs_section_at_top_level(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            lockfile = Path(temp_dir) / "Gemfile.lock"
            lockfile.write_text(
                "GEM\n"
                "  specs:\n"
                "    rails (7.1.0)\n"
                "DEPENDENCIES\n"
                "    fake-dependency (1.0.0)\n"
                "BUNDLED WITH\n"
                "   2.5.0\n",
                encoding="utf-8",
            )

            count, dependencies = parse_gemfile_lock(lockfile)

            self.assertEqual(count, 1)
            self.assertEqual(dependencies, {"bundler:rails"})


if __name__ == "__main__":
    unittest.main()
