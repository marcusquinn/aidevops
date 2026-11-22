#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the real compact archive CLI in disposable local Git repositories.

Keep this entry point and its test class names stable for existing CLI selectors.
Sibling case modules are mixins, not independently collected TestCase classes.
"""

import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from worktree_recovery_report_cases import RecoveryReportCases


def load_cases(suffix):
    """Load the scoped hyphenated sibling modules without relying on the cwd."""
    path = Path(__file__).with_name(f"test-worktree-archive-lifecycle-{suffix}.py")
    spec = importlib.util.spec_from_file_location(f"archive_lifecycle_{suffix}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


LifecycleCases = load_cases("cases").LifecycleCases
ScratchRecoveryCases = load_cases("scratch").ScratchRecoveryCases


class LegacyRecoveryReport(RecoveryReportCases, unittest.TestCase):
    pass


class ArchiveLifecycle(ScratchRecoveryCases, LifecycleCases, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
