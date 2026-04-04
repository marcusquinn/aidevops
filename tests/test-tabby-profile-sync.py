#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Tests for tabby-profile-sync.py compatibility and helpers."""

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent.parent / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

spec = importlib.util.spec_from_file_location(
    "tabby_profile_sync", SCRIPTS_DIR / "tabby-profile-sync.py"
)
tabby_profile_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tabby_profile_sync)


class TestTabbyProfileSync(unittest.TestCase):
    """Test Python 3.9-safe imports and helpers."""

    def test_module_imports_under_current_python(self):
        self.assertTrue(callable(tabby_profile_sync.extract_group_id))

    def test_extract_group_id_returns_projects_group(self):
        config_text = """groups:
  - id: abc-123
    name: Projects
  - id: def-456
    name: Other
profiles:
  - name: repo
"""

        self.assertEqual(tabby_profile_sync.extract_group_id(config_text), "abc-123")


if __name__ == "__main__":
    unittest.main()
