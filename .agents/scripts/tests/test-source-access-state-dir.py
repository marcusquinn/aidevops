#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GH#32834: the default broker state root must satisfy the broker's own ancestry rule."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

CORE_PATH = Path(__file__).resolve().parents[1] / "source_access_core.py"
SPEC = importlib.util.spec_from_file_location("source_access_core_state_dir_test", CORE_PATH)
assert SPEC and SPEC.loader
CORE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CORE
SPEC.loader.exec_module(CORE)


class DefaultStateDirTests(unittest.TestCase):
    def test_config_uses_platform_default(self) -> None:
        self.assertEqual(CORE.Config().state_dir, CORE.DEFAULT_STATE_DIR)
        expected = (
            "/private/var/db/aidevops/source-access"
            if sys.platform == "darwin"
            else "/var/run/aidevops/source-access"
        )
        self.assertEqual(str(CORE.DEFAULT_STATE_DIR), expected)

    def test_existing_ancestry_is_root_owned_and_not_group_or_world_writable(self) -> None:
        # Mirrors root_data_directory(): the walk starts at the deepest existing parent.
        existing = CORE.DEFAULT_STATE_DIR.parent.resolve(strict=False)
        while not existing.exists():
            existing = existing.parent
        for ancestor in (existing, *existing.parents):
            metadata = ancestor.stat()
            self.assertEqual(metadata.st_uid, 0, str(ancestor))
            self.assertEqual(metadata.st_mode & 0o022, 0, str(ancestor))


if __name__ == "__main__":
    unittest.main()
