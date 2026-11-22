#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GH#37514: maintainer resume approvals for stalled worker draft checkpoints."""

import copy
import importlib.util
import json
import pathlib
import sys
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS / "tests"))
from checkpoint_github_fixture import comment  # noqa: E402

_spec = importlib.util.spec_from_file_location("revision", SCRIPTS / "pr-checkpoint-revision.py")
revision = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(revision)

RELEASE_ID = 13
ATTEMPT = "attempt:continuation"


def attempt(first, actor, attempt_id, reason, releaser=None):
    """One claimed, ready attempt and its release; the owner closes its own lease."""
    releaser = releaser or actor
    lease = f"lease_token=tok{first} session=s{first} attempt_id={attempt_id}"
    events = [
        comment(first, f"DISPATCH_CLAIM nonce=tok{first} lease_token=tok{first} runner={actor} "
                       f"session=s{first} phase=prelaunch", actor),
        comment(first + 1, f"DISPATCH_LEASE phase=prelaunch {lease}", actor),
        comment(first + 2, f"DISPATCH_LEASE phase=ready {lease}", actor),
        comment(first + 3, f"CLAIM_RELEASED reason={reason} runner={releaser}", releaser),
    ]
    if releaser == actor:
        events.append(comment(first + 4, f"DISPATCH_LEASE phase=terminal {lease} expires_at=0", actor))
    return events


def stalled_fixture(reason="stale_assignment_reset", releaser="pulse-runner"):
    """The PR author's attempt handed off; a continuation by another runner stalled."""
    issue = {"number": 123, "state": "open", "body": "Brief", "assignees": [],
             "labels": [{"name": "origin:interactive"}, {"name": "status:available"}]}
    pr = {"number": 42, "headRefOid": "1" * 40, "headRefName": "worker/123",
          "author": {"login": "worker"}}
    comments = (attempt(1, "worker", "attempt:original", "worker_draft_checkpoint")
                + attempt(10, "other-worker", ATTEMPT, reason, releaser))
    return {"repo": "owner/repo", "pr": pr, "issue": issue, "comments": comments,
            "assignee": "", "now": revision.timestamp("2026-09-05T13:00:00Z")}


def approved(data):
    line = revision.template({**data, "release_id": RELEASE_ID, "attempt": ATTEMPT})
    return {**data, "comments": data["comments"] + [comment(30, line, "maintainer", "OWNER")]}


class StallApprovalTests(unittest.TestCase):
    def test_stall_class_releases_generate_valid_approvals(self):
        reasons = ("stale_assignment_reset", "no_activity", "wall_clock_stale", "worker_ownership_lost",
                   "worker_noop_zero_output", "worker_incomplete_exit", "watchdog_kill:no_activity",
                   "provider_timeout", "session_stall")
        for reason in reasons:
            for releaser in ("pulse-runner", "other-worker"):
                with self.subTest(reason=reason, releaser=releaser):
                    result = revision.validate(approved(stalled_fixture(reason, releaser)))
                    self.assertEqual((result["approval_id"], result["runner"]), (30, "worker"))

    def test_continuation_session_completed_release_generates_valid_approval(self):
        for reason in ("worker_complete", "clean"):
            with self.subTest(reason=reason):
                data = approved(stalled_fixture(reason, "other-worker"))
                self.assertEqual(revision.validate(data)["approval_id"], 30)

    def test_approval_rejects_head_brief_or_permission_change(self):
        data = approved(stalled_fixture())
        self.assertEqual(revision.validate(data)["approval_id"], 30)
        mutations = {
            "head": lambda d: d["pr"].update(headRefOid="2" * 40),
            "ref": lambda d: d["pr"].update(headRefName="worker/other"),
            "brief": lambda d: d["issue"].update(body="Brief changed"),
            "permission": lambda d: d["comments"][-1].update(author_association="NONE"),
            "expired": lambda d: d.update(now=d["now"] + 86401),
            "new_claim": lambda d: d["comments"].append(
                comment(31, "DISPATCH_CLAIM nonce=late lease_token=late runner=x session=late", "x")),
        }
        for case, mutate in mutations.items():
            changed = copy.deepcopy(data)
            mutate(changed)
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(changed)

    def test_live_owner_after_a_stall_release_blocks_the_approval(self):
        data = approved(stalled_fixture())
        renewal = comment(20, f"DISPATCH_LEASE phase=ready lease_token=tok10 session=s10 attempt_id={ATTEMPT}",
                          "other-worker")
        data["comments"].insert(-1, renewal)
        with self.assertRaises(ValueError):
            revision.validate(data)

    def test_unsupported_or_unbound_stall_releases_are_refused(self):
        def ambiguous_owner(d):
            d["comments"].insert(3, comment(3.5, f"DISPATCH_LEASE phase=ready lease_token=x attempt_id={ATTEMPT}",
                                            "stranger"))

        mutations = {
            "policy_timeout": lambda d: d["comments"][-1].update(
                body="CLAIM_RELEASED reason=push_policy_timeout runner=pulse-runner"),
            "draft_handoff": lambda d: d["comments"][-1].update(
                body="CLAIM_RELEASED reason=worker_draft_checkpoint runner=pulse-runner"),
            "runner_not_poster": lambda d: d["comments"][-1].update(
                body="CLAIM_RELEASED reason=stale_assignment_reset runner=other-worker"),
            "untrusted_poster": lambda d: d["comments"][-1].update(author_association="NONE"),
            "edited_release": lambda d: d["comments"][-1].update(updated_at="2026-09-05T12:01:00Z"),
            "no_ready_lease": lambda d: d["comments"].pop(-2),
            "ambiguous_owner": ambiguous_owner,
            "foreign_intervening": lambda d: d["comments"].insert(-1, comment(
                12.5, "DISPATCH_LEASE phase=ready lease_token=other session=s2 attempt_id=attempt:other",
                "other-worker")),
        }
        for case, mutate in mutations.items():
            data = stalled_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.template({**data, "release_id": RELEASE_ID, "attempt": ATTEMPT})

    def test_template_json_binds_the_release_and_attempt(self):
        data = approved(stalled_fixture())
        approval = json.loads(data["comments"][-1]["body"][len(revision.PREFIX):])
        self.assertEqual((approval["release_id"], approval["attempt"], approval["head"]),
                         (RELEASE_ID, ATTEMPT, "1" * 40))


if __name__ == "__main__":
    unittest.main()
