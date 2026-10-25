#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Permission-backed checkpoint regressions using the existing offline fixtures."""

import copy
import datetime as dt
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
fixture = shared["fixture"]
revision = shared["revision"]
comment = shared["comment"]
BASH = shared["BASH"]
SCRIPTS = shared["SCRIPTS"]


class PrivateMemberTests(unittest.TestCase):
    def test_events_and_edited_evidence(self):
        for association in ("CONTRIBUTOR", "NONE"):
            data = fixture()
            data["trusted_logins"] = ["worker", "maintainer"]
            for c in data["comments"]:
                c["author_association"] = association
            self.assertEqual(revision.validate(data)["approval_id"], 3)
            self.assertTrue(revision.template({**data, "release_id": 2,
                                              "attempt": "attempt:original"}).startswith(revision.PREFIX))
            for index in range(3):
                edited = copy.deepcopy(data)
                edited["comments"][index]["updated_at"] = "2026-09-05T12:01:00Z"
                with self.subTest(association=association, edited=index), self.assertRaises(ValueError):
                    revision.validate(edited)
                if index < 2:
                    with self.assertRaises(ValueError):
                        revision.template({**edited, "release_id": 2, "attempt": "attempt:original"})
            for logins in ([], ["worker"], ["maintainer"]):
                with self.subTest(logins=logins), self.assertRaises(ValueError):
                    revision.validate({**data, "trusted_logins": logins})
            data["comments"].append(comment(4, "DISPATCH_CLAIM nonce=new", "maintainer", association))
            with self.assertRaises(ValueError):
                revision.validate(data)

    def test_permission_backed_shell_paths(self):
        command = (
            'source "$1/pr-checkpoint-continuation-helper.sh"; '
            'gh() { case "$1 $2" in '
            '"pr view") printf "%s" "$TEST_PR" ;; '
            '"api repos/owner/repo/issues/123") printf "%s" "$TEST_ISSUE" ;; '
            '"api repos/owner/repo/issues/123/comments?per_page=100") printf "%s" "$TEST_COMMENTS" ;; '
            '"api repos/owner/repo/collaborators/maintainer/permission") printf "%s" "$TEST_PERMISSION" ;; '
            '*) return 90 ;; esac; return 0; }; '
            # Mock only HTTP transport, retaining the actual permission predicate.
            '_gh_collaborator_permission_request() { '
            'printf "HTTP/2 200 OK\\n\\n{\\"permission\\":\\"%s\\"}\\n" "$TEST_PERMISSION"; return 0; }; '
            'case "$TEST_MODE" in '
            'template) _pcc_approval_template owner/repo 42 123 2 attempt:original ;; '
            'validate) _pr_checkpoint_revised_target owner/repo "$TEST_PR" "$TEST_ISSUE" "$TEST_COMMENTS" worker ;; '
            'discovery) _pcc_dispatch() { return 0; }; _pcc_dispatch_approved owner/repo . 123 worker ;; '
            'evidence) logins=$(_pr_checkpoint_trusted_logins "$TEST_COMMENTS" owner/repo); '
            '_pcc_blocked_release_evidence "$TEST_COMMENTS" worker key "$logins" ;; esac'
        )
        for association in ("CONTRIBUTOR", "NONE"):
            for permission in ("admin", "maintain", "write", "read", "triage", "none", "unknown"):
                data = fixture()
                for c in data["comments"]:
                    c["author_association"] = association
                    c["created_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
                for mode in ("template", "validate", "discovery", "evidence"):
                    env = {**os.environ, "TEST_PERMISSION": permission, "TEST_MODE": mode,
                           "TEST_PR": json.dumps(data["pr"]), "TEST_ISSUE": json.dumps(data["issue"]),
                           "TEST_COMMENTS": json.dumps([data["comments"]])}
                    result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS)],  # nosec B603
                                            env=env, capture_output=True, text=True, check=False)
                    with self.subTest(association=association, permission=permission, mode=mode):
                        self.assertEqual(result.returncode == 0, permission in {"admin", "maintain", "write"},
                                         result.stderr)
                        if result.returncode == 0 and mode == "template":
                            self.assertTrue(result.stdout.startswith(revision.PREFIX))

    def test_edited_shell_events_remain_fences(self):
        command = ('source "$1/pr-checkpoint-continuation-helper.sh"; '
                   'case "$3" in '
                   'blocked) _pcc_blocked_release_evidence "$2" worker key \'["worker"]\' ;; '
                   'completed) _pcc_completed_release_evidence "$2" key \'["worker"]\' ;; '
                   'stall) _pcc_stall_release_evidence "$2" 2026-09-05T11:00:00Z key \'["worker"]\' ;; '
                   'expired) _pcc_expired_claim_evidence "$2" 2026-09-05T13:00:00Z 2000000000 \'["worker"]\' ;; esac')
        for mode, body in (("blocked", "CLAIM_RELEASED reason=blocked runner=worker"),
                           ("completed", "CLAIM_RELEASED reason=clean runner=worker"),
                           ("stall", "CLAIM_RELEASED reason=no_activity runner=worker"),
                           ("expired", "DISPATCH_CLAIM expires_at=1000000000")):
            event = comment(2, body, association="CONTRIBUTOR")
            cases = [(True, [event]),
                     (False, [{**event, "updated_at": "2026-09-05T12:01:00Z"}]),
                     (False, [event, {**comment(3, "DISPATCH_CLAIM nonce=new", association="CONTRIBUTOR"),
                                      "updated_at": "2026-09-05T12:01:00Z"}])]
            if mode != "expired":
                ready = comment(1, "DISPATCH_LEASE phase=ready lease_token=old", association="CONTRIBUTOR")
                terminal = comment(3, "DISPATCH_LEASE phase=terminal lease_token=old", association="CONTRIBUTOR")
                cases.extend([(True, [ready, event, terminal]),
                              (False, [ready, event, {**terminal, "updated_at": "2026-09-05T12:01:00Z"}])])
            for expected, comments in cases:
                result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS),  # nosec B603
                                         json.dumps(comments), mode], capture_output=True, check=False)
                with self.subTest(mode=mode, comments=comments):
                    self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_released_successor_history(self):
        data = shared["released_successor_fixture"]()
        data["trusted_logins"] = [c["user"]["login"] for c in data["comments"]]
        for c in data["comments"]:
            c["author_association"] = "CONTRIBUTOR"
        line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
        data["comments"].append(comment(20, line, "maintainer", "CONTRIBUTOR"))
        data["trusted_logins"].append("maintainer")
        self.assertEqual(revision.validate(data)["approval_id"], 20)
        data["comments"][2]["updated_at"] = "2026-09-05T12:01:00Z"
        with self.assertRaises(ValueError):
            revision.validate(data)


if __name__ == "__main__":
    unittest.main()
