#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Checkpoint approval discovery ordering using the existing offline fixtures."""

import json
import os
import pathlib
import runpy
import subprocess  # nosec B404 — fixed offline fixture programs only
import sys
import unittest

TESTS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))
shared = runpy.run_path(str(TESTS / "test-pr-checkpoint-revision.py"))
revision = shared["revision"]
comment = shared["comment"]
BASH = shared["BASH"]
SCRIPTS = shared["SCRIPTS"]


class DiscoveryTests(unittest.TestCase):
    def test_discovery_chooses_newest_trusted_unedited_approval(self):
        command = (
            'source "$1/pr-checkpoint-continuation-helper.sh"; '
            '_pcc_issue_comments() { printf "%s" "$TEST_COMMENTS"; return 0; }; '
            '_pr_checkpoint_trusted_logins() { printf "[]"; return 0; }; '
            '_pcc_dispatch() { printf "%s %s\\n" "$3" "$5"; return 0; }; '
            '_pcc_dispatch_approved owner/repo . 123 worker'
        )
        def approval(cid, pr, runner, timestamp):
            body = revision.PREFIX + json.dumps({"repo": "owner/repo", "issue": 123,
                                                 "pr": pr, "runner": runner})
            event = comment(cid, body, association="OWNER")
            event["created_at"] = event["updated_at"] = timestamp
            return event

        older = approval(1, 41, "old", "2026-11-10T00:00:00Z")
        newest = approval(3, 42, "new", "2026-11-12T00:00:00Z")
        tied = approval(2, 43, "tie", "2026-11-12T00:00:00Z")
        edited = approval(4, 44, "edited", "2026-11-13T00:00:00Z")
        edited["updated_at"] = "2026-11-14T00:00:00Z"
        for comments, expected in (([newest, older, edited, tied], "42 new\n"), ([], None)):
            result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS)],  # nosec B603
                                    env={**os.environ, "TEST_COMMENTS": json.dumps([comments])},
                                    capture_output=True, text=True, check=False)
            if expected is None:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("approval_discovery=", result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)


if __name__ == "__main__":
    unittest.main()
