#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Diagnostic approval cases discovered through the existing checkpoint runner.

The entry point supplies fixture, comment and revision validator attributes,
following checkpoint_admission_cases without introducing another test runner.
"""

import json


class DiagnosticToolingCases:
    def test_diagnostic_tooling_opt_in_roundtrip(self):
        data = self.fixture()
        data["comments"].pop()
        line = self.revision.template({**data, "release_id": 2, "attempt": "attempt:original",
                                       "diagnostic_tooling_commit": "a" * 40})
        data["comments"].append(self.comment(3, line, "maintainer", "OWNER"))
        self.assertEqual(self.revision.validate(data)["diagnostic_tooling_commit"], "a" * 40)
        data["issue"]["body"] += " changed"
        with self.assertRaises(ValueError):
            self.revision.validate(data)

    def test_diagnostic_tooling_rejects_non_immutable_values(self):
        for value in (None, True, {}, [], "", "main", "a" * 12, "A" * 40, "a" * 41):
            with self.subTest(value=value):
                data = self.fixture()
                data["comments"].pop()
                with self.assertRaises(ValueError):
                    self.revision.template({**data, "release_id": 2, "attempt": "attempt:original",
                                            "diagnostic_tooling_commit": value})
                approval = {**self.revision.binding(data), "attempt": "attempt:original",
                            "release_id": 2, "diagnostic_tooling_commit": value}
                data["comments"].append(self.comment(3, self.revision.PREFIX + json.dumps(approval),
                                                     "maintainer", "OWNER"))
                with self.assertRaises(ValueError):
                    self.revision.validate(data)

    def test_diagnostic_tooling_prose_does_not_grant_scope(self):
        data = self.fixture()
        data["comments"].pop()
        data["issue"]["body"] = "Use another worktree: diagnostic_tooling_commit=" + "a" * 40
        line = self.revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
        data["comments"].append(self.comment(3, line, "maintainer", "OWNER"))
        self.assertNotIn("diagnostic_tooling_commit", self.revision.validate(data))

    def test_diagnostic_tooling_requires_trusted_unedited_approval(self):
        for association, edited in (("NONE", False), ("OWNER", True)):
            with self.subTest(association=association, edited=edited):
                data = self.fixture()
                approval = json.loads(data["comments"][-1]["body"][len(self.revision.PREFIX):])
                approval["diagnostic_tooling_commit"] = "a" * 40
                latest = data["comments"][-1]
                latest["body"] = self.revision.PREFIX + json.dumps(approval)
                latest["author_association"] = association
                if edited:
                    latest["updated_at"] = "2026-09-05T12:30:00Z"
                with self.assertRaises(ValueError):
                    self.revision.validate(data)
