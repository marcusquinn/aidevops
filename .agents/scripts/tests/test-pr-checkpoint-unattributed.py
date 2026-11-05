#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#36593 unattributed-release acknowledgement regressions, using the shared fixtures."""

import copy
import json
import os
import pathlib
import runpy
import sys
import subprocess  # nosec B404 — existing offline GitHub fixture only
import tempfile
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


class TerminalWithoutReleaseTests(unittest.TestCase):
    def build(self):
        data = released_successor_fixture()
        data["comments"] = [c for c in data["comments"] if c["id"] != 13]
        expiry = str(int(revision.timestamp("2026-09-05T11:00:00Z")))
        for c in data["comments"]:
            if c["id"] >= 10:
                c["body"] += " device=reviewed-device"
                if c["id"] != 14:
                    c["body"] += " expires_at=" + expiry
        return data

    def generate(self, data, ids=None):
        return revision.template({**data, "release_id": 2, "attempt": "attempt:original",
                                  "acknowledge_terminal_without_release": [14] if ids is None else ids})

    def approved(self):
        data = self.build()
        data["comments"].append(comment(20, self.generate(data), "maintainer", "OWNER"))
        return data

    def test_exact_acknowledgement_preserves_missing_release(self):
        data = self.build()
        with self.assertRaises(ValueError):
            revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
        for ids in ([13], [14, 14], [14, 15], ["14"], [True], [-14]):
            with self.subTest(ids=ids), self.assertRaises(ValueError):
                self.generate(data, ids)
        result = revision.validate(self.approved())
        episode = result["released_successors"][-1]
        self.assertRegex(episode.pop("evidence_sha256"), r"^[0-9a-f]{64}$")
        self.assertEqual(episode, {"runner": "other-worker", "attempt": "attempt:closed-10",
            "claim_id": 10, "ready_id": 12, "terminal_id": 14, "outcome": "terminal_without_release",
            "release_provenance": "missing", "execution_status": "unrecovered"})
        self.assertNotIn("lease_token", self.generate(data))
        self.assertNotIn("release_id", episode)

    def test_acknowledgement_does_not_relax_identity_or_history(self):
        mutations = {
            "claim_edited": lambda d: d["comments"][-4].update(updated_at="2026-09-05T12:01:00Z"),
            "ready_edited": lambda d: d["comments"][-2].update(updated_at="2026-09-05T12:01:00Z"),
            "terminal_edited": lambda d: d["comments"][-1].update(updated_at="2026-09-05T12:01:00Z"),
            "foreign_actor": lambda d: d["comments"][-1]["user"].update(login="stranger"),
            "untrusted": lambda d: d["comments"][-1].update(author_association="NONE"),
            "missing_ready": lambda d: d["comments"].pop(-2),
            "missing_terminal": lambda d: d["comments"].pop(),
            "later_interactive": lambda d: d["comments"].append(comment(15, "Interactive session claimed")),
            "overlap": lambda d: d["comments"].insert(-1, comment(13,
                "DISPATCH_CLAIM nonce=overlap lease_token=overlap runner=worker session=other")),
        }
        for case, mutate in mutations.items():
            data = self.build()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.generate(data)
        for index, old, new in (
                (-1, "closed-10", "other-token"), (-1, "issue-10", "other-session"),
                (-1, "attempt:closed-10", "attempt:other"), (-1, "expires_at=0", "expires_at=1"),
                (-1, "reviewed-device", "other-device"), (-2, "reviewed-device", "other-device"),
                (-4, "device=reviewed-device", ""), (-3, "expires_at=", "unknown_expiry=")):
            data = self.build()
            data["comments"][index]["body"] = data["comments"][index]["body"].replace(old, new)
            with self.subTest(index=index, old=old), self.assertRaises(ValueError):
                self.generate(data)

    def test_live_unknown_or_not_yet_expired_at_approval_lease_rejects(self):
        for expiry in ("9999999999", "unknown", "0"):
            data = self.build()
            c = data["comments"][-2]
            c["body"] = c["body"].replace(c["body"].split("expires_at=")[1], expiry)
            with self.subTest(expiry=expiry), self.assertRaises(ValueError):
                self.generate(data)
        data = self.build()
        c = data["comments"][-2]
        c["body"] = c["body"].replace(c["body"].split("expires_at=")[1],
            str(int(revision.timestamp("2026-09-05T12:30:00Z"))))
        # Template time is 13:00, but this purported approval predates expiry.
        data["comments"].append(comment(20, self.generate(data), "maintainer", "OWNER"))
        with self.assertRaises(ValueError):
            revision.validate(data)

    def test_envelope_and_later_ownership_fences_remain(self):
        for case in ("head", "brief", "owner", "expiry", "interactive", "approval_edited", "history"):
            data = self.approved()
            if case == "head":
                data["pr"]["headRefOid"] = "2" * 40
            elif case == "brief":
                data["issue"]["body"] += " changed"
            elif case == "owner":
                data["issue"]["assignees"] = [{"login": "someone-else"}]
            elif case == "expiry":
                data["now"] += 86400
            elif case == "interactive":
                data["comments"].append(comment(21, "Interactive session claimed", "maintainer", "OWNER"))
            elif case == "approval_edited":
                data["comments"][-1]["updated_at"] = "2026-09-05T12:01:00Z"
            else:
                approval = json.loads(data["comments"][-1]["body"][len(revision.PREFIX):])
                approval["released_successors"][-1]["execution_status"] = "completed"
                data["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(data)

    def test_anomalous_attempt_token_cannot_be_reused(self):
        data = self.approved()
        data.update(lease="closed-10", session="checkpoint-42", assignee="next-worker", claiming=True)
        data["comments"].append(comment(21, "DISPATCH_CLAIM nonce=closed-10 lease_token=closed-10 "
            "runner=next-worker checkpoint_approval=20 session=checkpoint-42 expires_at=1788620400", "next-worker"))
        with self.assertRaises(ValueError):
            revision.validate(data)

    def test_approval_binds_intermediate_coordination_records(self):
        approved = self.approved()
        for case in ("deleted_prelaunch", "changed_expiry", "changed_created_at", "extra_renewal"):
            data = copy.deepcopy(approved)
            if case == "deleted_prelaunch":
                data["comments"] = [c for c in data["comments"] if c["id"] != 11]
            elif case == "changed_expiry":
                c = next(c for c in data["comments"] if c["id"] == 11)
                c["body"] = c["body"].replace("expires_at=", "expires_at=1")
            elif case == "changed_created_at":
                next(c for c in data["comments"] if c["id"] == 11)["created_at"] = "2026-09-05T11:59:59Z"
            else:
                renewal = copy.deepcopy(next(c for c in data["comments"] if c["id"] == 12))
                renewal["id"] = 13
                data["comments"].insert(-2, renewal)
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(data)

    def test_cli_combines_both_explicit_acknowledgements_without_github_writes(self):
        data = self.build()
        data["comments"].append(comment(15, "CLAIM_RELEASED reason=worker_complete runner=worker"))
        with tempfile.TemporaryDirectory() as root:
            state = pathlib.Path(root) / "state.json"
            state.write_text(json.dumps(data))
            gh = pathlib.Path(root) / "gh"
            gh.write_text('#!/usr/bin/env bash\nexec python3 "$CHECKPOINT_TEST_FILE" --gh "$@"\n')
            gh.chmod(0o700)
            env = {**os.environ, "PATH": root + os.pathsep + os.environ["PATH"], "HOME": root,
                   "CHECKPOINT_TEST_FILE": str(TESTS / "checkpoint_github_fixture.py"),
                   "CHECKPOINT_TEST_STATE": str(state), "AIDEVOPS_TEST_MODE": "1"}
            command = [shared["BASH"], str(TESTS.parent / "pr-checkpoint-continuation-helper.sh"),
                       "approval-template", "owner/repo", "42", "123", "2", "attempt:original"]
            flags = ["--acknowledge-terminal-without-release=14", "--acknowledge-unattributed=15"]
            for options in (flags, list(reversed(flags))):
                result = subprocess.run(command + options, env=env, capture_output=True, text=True,  # nosec B603
                                        timeout=30, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                approval = json.loads(result.stdout[len(revision.PREFIX):])
                self.assertEqual([item.get("outcome") for item in approval["released_successors"]],
                                 [None, "terminal_without_release", "unattributed_release"])
            for options in (flags + ["--unknown=14"], flags + flags, [flags[0]]):
                result = subprocess.run(command + options, env=env, capture_output=True, text=True,  # nosec B603
                                        timeout=30, check=False)
                self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(state.read_text()), data)


if __name__ == "__main__":
    unittest.main()
