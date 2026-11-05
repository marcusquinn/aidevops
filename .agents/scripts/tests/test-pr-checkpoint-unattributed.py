#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#36593 unattributed-release acknowledgement regressions, using the shared fixtures."""

import json
import pathlib
import runpy
import sys
import unittest

TESTS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))
shared = runpy.run_path(str(TESTS / "test-pr-checkpoint-revision.py"))
revision = shared["revision"]
comment = shared["comment"]
released_successor_fixture = shared["released_successor_fixture"]


class UnattributedReleaseTests(unittest.TestCase):
    TOKEN_FIELD = "lease_" + "token="

    def orphan_fixture(self):
        """GH#36593: a trusted release follows fully closed attempts with no claim."""
        data = released_successor_fixture()
        data["comments"].append(comment(15, "CLAIM_RELEASED reason=worker_complete runner=worker "
                                            + self.TOKEN_FIELD + "orphan-token"))
        return data

    def acknowledged(self, data, ids):
        return revision.template({**data, "release_id": 2, "attempt": "attempt:original",
                                  "acknowledge_unattributed": ids})

    def test_unattributed_release_requires_exact_acknowledgement(self):
        data = self.orphan_fixture()
        for ids in ([], [16], [15, 16], ["15"], [True]):
            with self.subTest(ids=ids), self.assertRaises(ValueError):
                self.acknowledged(data, ids)
        line = self.acknowledged(data, [15])
        approved = {**data, "comments": data["comments"] + [comment(20, line, "maintainer", "OWNER")]}
        history = revision.validate(approved)["released_successors"]
        self.assertEqual(history[-1], {"runner": "worker", "release_id": 15, "outcome": "unattributed_release",
                                       "reason": "worker_complete", "provenance": "unrecovered"})
        self.assertNotIn("orphan-token", line)
        approval = json.loads(line[len(revision.PREFIX):])
        approval["released_successors"].pop()
        approved["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
        with self.assertRaises(ValueError):
            revision.validate(approved)

    def test_unattributed_release_keeps_every_other_rejection(self):
        mutations = {
            "edited": lambda d: d["comments"][-1].update(updated_at="2026-09-05T12:01:00Z"),
            "untrusted": lambda d: d["comments"][-1].update(author_association="NONE"),
            "inside_open_episode": lambda d: d["comments"].insert(6, comment(
                10.5, "CLAIM_RELEASED reason=worker_complete runner=other-worker", "other-worker")),
            "malformed_reason": lambda d: d["comments"][-1].update(
                body="CLAIM_RELEASED reason=Worker-Complete runner=worker"),
            "stray_lease": lambda d: d["comments"][-1].update(
                body="DISPATCH_LEASE phase=ready " + self.TOKEN_FIELD + "x session=s attempt_id=attempt:x"),
        }
        for case, mutate in mutations.items():
            data = self.orphan_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.acknowledged(data, [15])

    def test_unattributed_release_token_stays_fenced(self):
        data = self.orphan_fixture()
        line = self.acknowledged(data, [15])
        data["comments"].append(comment(20, line, "maintainer", "OWNER"))
        data.update(lease="orphan-token", session="checkpoint-42", assignee="next-worker", claiming=True)
        data["comments"].append(comment(21, "DISPATCH_CLAIM nonce=orphan-token " + self.TOKEN_FIELD
            + "orphan-token runner=next-worker checkpoint_approval=20 session=checkpoint-42 "
            "expires_at=1788620400", "next-worker"))
        with self.assertRaises(ValueError):
            revision.validate(data)


if __name__ == "__main__":
    unittest.main()
