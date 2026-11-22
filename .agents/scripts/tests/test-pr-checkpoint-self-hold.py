#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#36138: an exact approval supersedes only its runner's own draft hold-for-review."""

import datetime as dt
import json
import pathlib
import runpy
import subprocess  # nosec B404 — fixed offline fixture programs only
import sys
import unittest

TESTS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))
shared = runpy.run_path(str(TESTS / "test-pr-checkpoint-revision.py"))
unlabelled_blocked_fixture = shared["unlabelled_blocked_fixture"]
revision = shared["revision"]
comment = shared["comment"]
BASH = shared["BASH"]
SCRIPTS = shared["SCRIPTS"]

BEFORE = "2020-01-01T00:00:00Z"
AFTER = "2099-01-01T00:00:00Z"
PR_ONLY = "Corrected scope\n<!-- aidevops:completion-contract:pr-only/v1 -->"
AUTOMATION_HOLD = "<!-- feedback-route:automation-hold:review:{pr}:SHA" + "1" * 40 + ":REASONx -->"
# Unknown gh calls fail (90); JSON null stands for unreadable PR label history.
COMMAND = ('source "$1/pr-checkpoint-target-lib.sh"; TEST_EVENTS="$6"; TEST_PR_EVENTS="$7"; '
           'gh() { case "$*" in '
           '"api repos/owner/repo/issues/123/events?per_page=100 --paginate --slurp") '
           'printf "%s" "$TEST_EVENTS"; return 0 ;; '
           '"api repos/owner/repo/issues/42/events?per_page=100 --paginate --slurp") '
           '[[ "$TEST_PR_EVENTS" != null ]] || return 1; printf "%s" "$TEST_PR_EVENTS"; return 0 ;; '
           '"api repos/owner/repo/collaborators/maintainer/permission --jq .permission") '
           'printf "%s" write; return 0 ;; esac; return 90; }; '
           '_pr_checkpoint_revised_target "$2" "$3" "$4" "$5" worker')


def hold(actor, created_at=BEFORE, event="labeled"):
    return {"event": event, "label": {"name": "hold-for-review"}, "actor": {"login": actor},
            "created_at": created_at}


def approved(body="Corrected scope", held=True):
    """An exact approved checkpoint whose runner (the PR author) held its own draft first."""
    data = unlabelled_blocked_fixture()
    # The approval binds the brief digest, so regenerate it for the chosen body.
    data["issue"]["body"] = body
    data["comments"].pop()
    line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
    data["comments"].append(comment(3, line, "maintainer", "OWNER"))
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    data["comments"] = [{**c, "created_at": now} for c in data["comments"]]
    data["pr"]["labels"] += [{"name": "hold-for-review"}] if held else []
    data["pr_events"] = [[hold("worker")]]
    return data


def run(candidate):
    """Return (rc, stdout) from the shell trust boundary with mocked GitHub reads."""
    documents = [candidate[key] for key in ("pr", "issue", "comments", "issue_events", "pr_events")]
    # Fixed Bash source and locally constructed JSON are positional data, never shell source.
    result = subprocess.run([BASH, "-c", COMMAND, "test", str(SCRIPTS), candidate["repo"],  # nosec B603
                             *map(json.dumps, documents)], capture_output=True, check=False, text=True)
    return result.returncode, result.stdout


class SelfHoldSupersessionTests(unittest.TestCase):
    def assert_superseded(self, candidate, expected):
        rc, out = run(candidate)
        self.assertEqual(rc, 0, out)
        self.assertIs(json.loads(out)["self_hold_superseded"], expected)

    def test_runner_self_hold_before_approval_is_superseded(self):
        self.assert_superseded(approved(), True)
        self.assert_superseded(approved(held=False), False)
        relabelled = approved()
        relabelled["pr_events"][0] += [hold("worker", "2020-01-02T00:00:00Z", "unlabeled"),
                                       hold("worker", "2020-01-03T00:00:00Z"),
                                       {"event": "labeled", "label": {"name": "bug"},
                                        "actor": {"login": "other"}, "created_at": AFTER}]
        self.assert_superseded(relabelled, True)

    def test_foreign_late_or_unprovable_holds_still_protect(self):
        rejections = {
            "another actor's hold": [[hold("maintainer")]],
            "runner hold plus another actor's hold": [[hold("worker"), hold("maintainer", "2020-01-02T00:00:00Z")]],
            "runner hold reapplied after approval": [[hold("worker"), hold("worker", AFTER)]],
            "hold label without a labeled event": [[]],
            "unreadable PR events": None,
        }
        for case, pr_events in rejections.items():
            candidate = approved()
            candidate["pr_events"] = pr_events
            self.assertNotEqual(run(candidate)[0], 0, case)

    def test_merge_and_release_gates_are_never_superseded(self):
        # The PR-only brief is otherwise approvable without the hold label.
        self.assert_superseded(approved(body=PR_ONLY, held=False), False)
        self.assertNotEqual(run(approved(body=PR_ONLY))[0], 0, "PR-only completion contract")
        release_gated = approved()
        release_gated["pr"]["labels"].append({"name": "release-approval-required"})
        self.assertNotEqual(run(release_gated)[0], 0, "release approval gate")

    def test_feedback_route_automation_hold_for_this_pr_protects(self):
        for held, pr_ref, accepted in ((False, "PR42", True), (True, "PR42", False), (True, "PR420", True)):
            candidate = approved(held=held)
            record = comment(2.5, AUTOMATION_HOLD.format(pr=pr_ref), "worker", "MEMBER")
            record["created_at"] = candidate["comments"][1]["created_at"]
            candidate["comments"].insert(2, record)
            self.assertEqual(run(candidate)[0] == 0, accepted, (held, pr_ref))


if __name__ == "__main__":
    unittest.main()
