#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mocked GitHub regression cases for corrected checkpoint authorization."""

import copy
import datetime as dt
import hashlib
import importlib.util
import itertools
import json
import os
import pathlib
import shutil
import subprocess  # nosec B404 — executes fixed offline fixture programs only
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
if not BASH or not pathlib.Path(BASH).is_absolute():
    raise RuntimeError("An absolute path to the installed Bash runtime is required")
sys.path.insert(0, str(SCRIPTS))
from checkpoint_github_fixture import comment
from checkpoint_admission_cases import AutomaticBindingCases, ProgressCases, RevisionEnvelopeCases
from checkpoint_diagnostic_tooling_cases import DiagnosticToolingCases
from checkpoint_launch_failure_cases import LaunchFailureCases
from pr_checkpoint_events import EVENTS, fields, own_claim_matches
import integration_recovery as recovery


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


revision = load("revision", "pr-checkpoint-revision.py")
admission = load("admission", "pr_checkpoint_admission.py")
queue = load("queue", "pulse-check-queue-scan.py")


def fixture():
    issue = {"number": 123, "state": "open", "body": "Corrected scope", "assignees": [{"login": "worker"}],
             "labels": [{"name": "origin:interactive"}, {"name": "status:in-review"}]}
    pr = {"number": 42, "state": "OPEN", "isDraft": True, "isCrossRepository": False,
          "headRefOid": "1" * 40, "headRefName": "worker/123", "author": {"login": "worker"},
          "labels": [{"name": "origin:worker"}], "body": "For #123. Partial work.",
          "closingIssuesReferences": []}
    approval = {"repo": "owner/repo", "issue": 123, "pr": 42, "head": "1" * 40,
                "ref": "worker/123", "runner": "worker", "attempt": "attempt:original",
                "release_id": 2, "brief_sha256": hashlib.sha256(issue["body"].encode()).hexdigest()}
    comments = [comment(1, "DISPATCH_LEASE phase=ready lease_token=old session=issue-123 attempt_id=attempt:original"),
                comment(2, "CLAIM_RELEASED reason=blocked runner=worker lease_token=old"),
                comment(3, revision.PREFIX + json.dumps(approval), "maintainer", "OWNER")]
    return {"repo": "owner/repo", "pr": pr, "issue": issue, "comments": comments,
            "assignee": "worker", "now": revision.timestamp("2026-09-05T13:00:00Z")}


def completed_release_fixture(reason="worker_complete", actor="recovering-worker"):
    """A completed continuation releases another author's preserved draft."""
    data = fixture()
    data["comments"] = data["comments"][:2]
    ready, release = data["comments"]
    ready["user"]["login"] = actor
    ready["body"] = ready["body"].replace("attempt:original", "original")
    release["user"]["login"] = actor
    release["body"] = f"CLAIM_RELEASED reason={reason} runner={actor}"
    data["issue"]["assignees"] = [{"login": actor}]
    return data


def unlabelled_blocked_fixture():
    """An exact approved checkpoint has lost provenance and is solely blocked."""
    data = fixture()
    data["pr"]["labels"] = []
    data["issue"]["labels"][1] = {"name": "status:blocked"}
    data["issue"]["updated_at"] = "2026-09-05T11:00:00Z"
    data["issue_events"] = [{"event": "labeled", "label": {"name": "status:blocked"},
                             "created_at": data["issue"]["updated_at"]}]
    data["comments"].pop()
    line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
    data["comments"].append(comment(3, line, "maintainer", "OWNER"))
    return data


def insert_renewed_attempt(data):
    """Insert a same-actor ready lease for a different attempt before the release."""
    renewed = copy.deepcopy(data["comments"][0])
    renewed.update(id=1.5, body=renewed["body"].replace("original", "other"))
    data["comments"].insert(1, renewed)


class RevisionTests(LaunchFailureCases, DiagnosticToolingCases, RevisionEnvelopeCases, unittest.TestCase):
    fixture = staticmethod(fixture)
    comment = staticmethod(comment)
    revision = revision
    bash = BASH
    scripts = SCRIPTS

    def test_legacy_release_and_ambiguous_attempt(self):
        data = fixture()
        data["comments"][1]["body"] = "CLAIM_RELEASED reason=blocked runner=worker"
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        data["comments"].insert(0, comment(0, "DISPATCH_LEASE phase=ready lease_token=other attempt_id=attempt:original"))
        with self.assertRaises(ValueError):
            revision.validate(data)

    def test_unassigned_and_newer_coordination(self):
        data = fixture()
        data["issue"]["assignees"] = []
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        for event in EVENTS:
            with self.subTest(event=event), self.assertRaises(ValueError):
                revision.validate({**data, "comments": data["comments"] + [comment(4, event + "new-owner")]})

    def test_released_revised_lifecycle_requires_current_approval_snapshot(self):
        self.assertEqual(revision.validate(fixture())["approval_id"], 3)
        data = unlabelled_blocked_fixture()
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        # The approval comment's own issue update is acceptable.
        data["issue"]["updated_at"] = data["comments"][-1]["created_at"]
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        missing_metadata = copy.deepcopy(data["issue"])
        missing_metadata.pop("updated_at")
        self.assertRaises(ValueError, revision.validate, {**data, "issue": missing_metadata})
        without_snapshot = {**data["comments"][-1], "body": fixture()["comments"][-1]["body"]}
        self.assertRaises(ValueError, revision.validate,
                          {**data, "comments": data["comments"][:-1] + [without_snapshot]})

    def test_completed_release_retains_author_binding_and_actual_owner(self):
        for reason in ("clean", "worker_complete"):
            with self.subTest(reason=reason):
                self.assert_completed_release_owner(reason)

    def assert_completed_release_owner(self, reason):
        data = completed_release_fixture(reason)
        ready = data["comments"][0]
        data["comments"].append(comment(3, ready["body"].replace(
            "phase=ready", "phase=terminal") + " expires_at=0", "recovering-worker"))
        line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
        data["comments"].append(comment(4, line, "maintainer", "OWNER"))
        self.assertEqual(revision.validate(data)["runner"], "worker")
        self.assertEqual(revision.validate(data)["approval_id"], 4)
        data["issue"]["assignees"] = []
        self.assertEqual(revision.validate(data)["approval_id"], 4)
        data["issue"]["assignees"] = [{"login": "unrelated-owner"}]
        with self.assertRaises(ValueError):
            revision.validate(data)

    def test_completed_release_rejects_unbound_or_edited_evidence(self):
        edited = "2026-09-05T12:01:00Z"
        mutations = {
            "blocked_other_actor": lambda d: d["comments"][1].update(
                body="CLAIM_RELEASED reason=blocked runner=recovering-worker"),
            "poster": lambda d: d["comments"][1]["user"].update(login="stranger"),
            "ready_actor": lambda d: d["comments"][0]["user"].update(login="stranger"),
            "ready_attempt": lambda d: d["comments"][0].update(
                body=d["comments"][0]["body"].replace("original", "other")),
            "missing_ready": lambda d: d["comments"].pop(0),
            "edited_release": lambda d: d["comments"][1].update(updated_at=edited),
            "edited_ready": lambda d: d["comments"][0].update(updated_at=edited),
            "renewed_attempt": insert_renewed_attempt,
        }
        self.assert_mutations_rejected(mutations, completed_release_fixture, lambda d: revision.template(
            {**d, "release_id": 2, "attempt": "attempt:original"}))

    def assert_mutations_rejected(self, mutations, build, check):
        for case, mutate in mutations.items():
            data = build()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                check(data)

    def test_completed_release_approval_still_requires_current_exact_envelope(self):
        data = completed_release_fixture()
        line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
        data["comments"].append(comment(3, line, "maintainer", "OWNER"))
        mutations = {
            "head": lambda d: d["pr"].update(headRefOid="2" * 40),
            "body": lambda d: d["issue"].update(body=d["issue"]["body"] + " changed"),
            "stale": lambda d: d.update(now=d["now"] + 86400),
            "new_claim": lambda d: d["comments"].append(
                comment(4, "Interactive session claimed", "maintainer")),
        }
        self.assert_mutations_rejected(mutations, lambda: copy.deepcopy(data), revision.validate)

    def test_released_attempt_terminal_lease_is_not_a_successor(self):
        # GH#33839: production launchers close the released lease after CLAIM_RELEASED.
        def with_closing(field, author="worker", phase="terminal"):
            data = fixture()
            body = f"DISPATCH_LEASE phase={phase} {field} session=issue-123 expires_at=0"
            data["comments"].insert(2, {**comment(4, body, author), "id": 2.5})
            return data

        original = next(part for part in fixture()["comments"][0]["body"].split()
                        if part.startswith("lease_token="))
        self.assertEqual(revision.validate(with_closing(original))["approval_id"], 3)
        for field, author, phase in [("lease_token=unseen", "worker", "terminal"),
                                     (original, "other", "terminal"),
                                     (original, "worker", "ready")]:
            with self.subTest(field=field, author=author, phase=phase), self.assertRaises(ValueError):
                revision.validate(with_closing(field, author, phase))

    def test_own_claim_and_lease_are_required_after_transfer(self):
        data = fixture()
        data.update(lease="new", session="checkpoint-42", assignee="next-worker", claiming=True)
        data["comments"].append(comment(4, "DISPATCH_CLAIM nonce=new lease_token=new runner=next-worker "
                                          "checkpoint_approval=3 session=checkpoint-42 expires_at=1788620400", "next-worker"))
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        data["claiming"] = False
        with self.assertRaises(ValueError):
            revision.validate(data)
        data["issue"]["assignees"] = [{"login": "next-worker"}]
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        for key, value in [("lease", "wrong"), ("session", "wrong"), ("now", data["now"] + 20000)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                revision.validate({**data, key: value})

    def not_launched_attempt(self, first_id, lease, reason="worker_not_launched", author="next-worker"):
        field = "lease_" + "token"
        return [
            comment(first_id, f"DISPATCH_CLAIM nonce={lease} {field}={lease} runner={author} "
                              "checkpoint_approval=3 session=checkpoint-42 expires_at=1788620400", author),
            comment(first_id + 0.1, f"DISPATCH_LEASE phase=ready {field}={lease} session=checkpoint-42 "
                                    "attempt_id=attempt:failed expires_at=1788620400", author),
            comment(first_id + 0.2, f"CLAIM_RELEASED reason={reason} runner={author} {field}={lease}", author),
            comment(first_id + 0.3, f"DISPATCH_LEASE phase=terminal {field}={lease} session=checkpoint-42 "
                                    "expires_at=0", author),
        ]

    def test_not_launched_release_with_attempt_log_keeps_approval_reusable(self):
        data = fixture()
        data["issue"]["assignees"] = []
        attempt = self.not_launched_attempt(4, "failed1")
        attempt[2]["body"] += " attempt_log=worker-checkpoint-42.log.ABC123"
        data["comments"] += attempt
        self.assertEqual(revision.validate(data)["approval_id"], 3)

    def test_not_launched_attempt_keeps_exact_head_approval_reusable(self):
        # GH#37669: a revision attempt whose runtime never launched changed
        # nothing on the approved head, so the same approval stays usable.
        field = "lease_" + "token"
        data = fixture()
        data["issue"]["assignees"] = []
        data["comments"] += self.not_launched_attempt(4, "failed1")
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        data.update(lease="new", session="checkpoint-42", assignee="next-worker", claiming=True)
        data["comments"].append(comment(9, f"DISPATCH_CLAIM nonce=new {field}=new runner=next-worker "
                                           "checkpoint_approval=3 session=checkpoint-42 expires_at=1788620400",
                                        "next-worker"))
        self.assertEqual(revision.validate(data)["approval_id"], 3)

        rejected = {
            "launched_release": lambda d: d["comments"][5].update(
                body=d["comments"][5]["body"].replace("worker_not_launched", "worker_complete")),
            "foreign_release": lambda d: d["comments"][5]["user"].update(login="stranger"),
            "other_approval": lambda d: d["comments"][3].update(
                body=d["comments"][3]["body"].replace("checkpoint_approval=3", "checkpoint_approval=99")),
            "edited_release": lambda d: d["comments"][5].update(updated_at="2026-09-05T12:01:00Z"),
            "open_attempt": lambda d: d["comments"].__delitem__(slice(5, 7)),
        }
        base = fixture()
        base["issue"]["assignees"] = []
        base["comments"] += self.not_launched_attempt(4, "failed1")
        self.assert_mutations_rejected(rejected, lambda: copy.deepcopy(base), revision.validate)

        bounded = fixture()
        bounded["issue"]["assignees"] = []
        for index in range(revision.MAX_NOT_LAUNCHED_REUSES):
            bounded["comments"] += self.not_launched_attempt(4 + index, f"failed{index}")
        self.assertEqual(revision.validate(bounded)["approval_id"], 3)
        bounded["comments"] += self.not_launched_attempt(20, "failed-extra")
        with self.assertRaises(ValueError):
            revision.validate(bounded)

    def test_shell_predicate_preserves_holds_and_linkage(self):
        data = unlabelled_blocked_fixture()
        # Supply current wall time for the shell boundary, avoiding date-dependent fixtures.
        for c in data["comments"]:
            c["created_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        command = ('source "$1/pr-checkpoint-target-lib.sh"; TEST_EVENTS="$6"; '
                   'gh() { if [[ "$*" == "api repos/owner/repo/issues/123/events?per_page=100 --paginate --slurp" ]]; then '
                   'printf "%s" "$TEST_EVENTS"; return 0; fi; '
                   '[[ "$*" == "api repos/owner/repo/collaborators/maintainer/permission --jq .permission" ]] || return 90; '
                   'printf "%s" "${TEST_PERMISSION:-write}"; }; '
                   '_pr_checkpoint_revised_target "$2" "$3" "$4" "$5" worker')
        def run(candidate):
            # Fixed Bash source and locally constructed JSON are positional data, never shell source.
            return subprocess.run([BASH, "-c", command, "test", str(SCRIPTS), candidate["repo"],  # nosec B603
                                   json.dumps(candidate["pr"]), json.dumps(candidate["issue"]),
                                   json.dumps(candidate["comments"]),
                                   json.dumps(candidate["issue_events"])], capture_output=True, check=False).returncode
        self.assertEqual(run(data), 0)
        changed = copy.deepcopy(data)
        # A comment/claim update alone must not invalidate the blocked snapshot.
        changed["issue"]["updated_at"] = "2099-01-01T00:00:00Z"
        unassigned_issue = {**changed["issue"], "assignees": []}
        self.assertEqual(run(changed), 0)
        self.assertEqual(run({**changed, "issue": unassigned_issue}), 0)
        # Reapply the same sole blocked label after approval: reject both owner
        # states even though the current label set matches the approved one.
        changed["issue_events"].append({"event": "labeled", "label": {"name": "status:blocked"},
                                        "created_at": changed["issue"]["updated_at"]})
        self.assertNotEqual(run(changed), 0)
        self.assertNotEqual(run({**changed, "issue": unassigned_issue}), 0)
        shared_holds = ("hold-for-review", "needs-maintainer-review", "no-auto-dispatch", "persistent")
        label_cases = itertools.chain(
            itertools.product(("pr", "issue"), shared_holds),
            (("pr", "no-takeover"), ("issue", "needs-maintainer-permissions")),
            itertools.product(("issue",), ("blocked", "status:available", "status:in-progress", "status:done")),
        )
        for surface, label in label_cases:
            changed = copy.deepcopy(data)
            changed[surface]["labels"].append({"name": label})
            self.assertNotEqual(run(changed), 0, (surface, label))
        invalidations = (
            ("missing", {"comments": data["comments"][:-1]}),
            ("head", {"pr": {**data["pr"], "headRefOid": "2" * 40}}),
            ("body", {"issue": {**data["issue"], "body": data["issue"]["body"] + " changed"}}),
            ("expired", {"comments": data["comments"][:-1] + [
                {**data["comments"][-1], "created_at": "2020-01-01T00:00:00Z"}]}),
            ("owner", {"issue": {**data["issue"], "assignees": [{"login": "other"}]}}),
            ("successor", {"comments": data["comments"] + [
                comment(4, "Interactive session claimed", "maintainer")]}),
            ("prefix collision", {"pr": {**data["pr"], "body": "For #1234"}}),
            ("bare mention", {"pr": {**data["pr"], "body": "mentions #123"}}),
            ("ambiguous linkage", {"pr": {**data["pr"], "body": "For #123 and #124"}}),
        )
        for case, overrides in invalidations:
            self.assertNotEqual(run({**data, **overrides}), 0, case)

    def test_claim_handoff_prelaunch_ready_and_rollback(self):
        # REST hygiene changes updated_at, not the body. The real claim
        # subprocess must verify GraphQL lastEditedAt for historical claim 4.
        minimized = {4: {"updated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "lastEditedAt": None}}
        # (unassigned, fixture builder, generated approval, per-comment metadata)
        cases = ((False, fixture, False, {}), (True, fixture, False, {}),
                 (True, released_successor_fixture, True, {}),
                 (False, completed_release_fixture, True, {}), (True, completed_release_fixture, True, {}),
                 (False, unlabelled_blocked_fixture, False, {}), (True, unlabelled_blocked_fixture, False, {}),
                 (True, released_successor_fixture, True, minimized))
        for unassigned, build, approve, comment_edits in cases:
            with self.subTest(unassigned=unassigned, fixture=build.__name__, minimized=bool(comment_edits)), tempfile.TemporaryDirectory() as root:
                data = build()
                if approve:
                    line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
                    data["comments"].append(comment(20, line, "maintainer", "OWNER"))
                approval_id = data["comments"][-1]["id"]
                # GH#31305 producer -> coordinator -> existing fenced worker
                # continuation. The request itself is never checkpoint approval.
                data["issue"]["title"] = "Preserve checkpoint integration"
                data["pr"]["title"] = "Preserve checkpoint integration"
                blocked = copy.deepcopy(data)
                blocked["issue"]["body"] = "Hard boundary: do not modify src/claim.sh"
                request = {"schema": 1, "issue": 123, "pr": 42, "reason": "hard_boundary",
                           "files": ["src/claim.sh"], "evidence": "shared claim integration needed",
                           "verification": ["bash test-pr-checkpoint-continuation-helper.sh"]}
                output = json.dumps({"type": "text", "text": "BLOCKED: integration boundary\n" +
                                     recovery.MARKER + json.dumps(request)})
                envelope = {"repo": data["repo"], "issue": 123, "pr": 42,
                            "head": data["pr"]["headRefOid"], "branch": data["pr"]["headRefName"],
                            "attempt": "attempt:original", "session": "issue-123", "brief": blocked["issue"]}
                with recovery.connect(pathlib.Path(root) / "recovery") as db:
                    produced = recovery.capture(db, envelope, recovery.final_request(output))
                    self.assertEqual(produced["action"], "coordinator")
                    observed = {"issue": blocked["issue"], "comments": [], "dependencies": []}
                    recovery.observe(db, produced["id"], observed)
                    recovery.decide(db, produced["id"], {"wake": "brief_revision", "actor": "maintainer",
                                    "next_action": "authorized brief owner corrects scope and signs exact checkpoint revision",
                                    "evidence": "retain PR 42, do not approve worker authority expansion"})
                    with self.assertRaises(ValueError):
                        revision.validate(blocked)
                    # Existing fixture supplies the separate trusted revision
                    # approval only after the canonical brief is corrected.
                    observed["issue"] = data["issue"]
                    resumed = recovery.observe(db, produced["id"], observed)
                    self.assertEqual((resumed["pr"], resumed["branch"]), (42, "worker/123"))
                    self.assertEqual(revision.validate(data)["approval_id"], approval_id)
                if unassigned:
                    data["issue"]["assignees"] = []
                    status = data["issue"]["labels"][1]["name"]
                    # Release the assigned lifecycle without erasing an approved block.
                    data["issue"]["labels"][1] = {"name": {"status:in-review": "status:available"}.get(status, status)}
                for c in data["comments"]:
                    c["created_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
                    c.update(comment_edits.get(c["id"], {}))
                state = pathlib.Path(root) / "state.json"
                state.write_text(json.dumps(data))
                gh = pathlib.Path(root) / "gh"
                gh.write_text('#!/usr/bin/env bash\nexec python3 "$CHECKPOINT_TEST_FILE" --gh "$@"\n')
                gh.chmod(0o700)
                env = {**os.environ, "PATH": root + os.pathsep + os.environ["PATH"], "HOME": root,
                       "CHECKPOINT_TEST_FILE": str(pathlib.Path(__file__).with_name("checkpoint_github_fixture.py")), "CHECKPOINT_TEST_STATE": str(state),
                       "CHECKPOINT_TEST_APPROVAL": str(approval_id),
                        "CHECKPOINT_TEST_READY": str(build is fixture and not unassigned).lower(),
                        "CHECKPOINT_TEST_RENEW": str(not (build is fixture and unassigned)).lower(),
                       # Do not renew this fixture's lease under the invoking
                       # headless worker's real dispatch session.
                       "AIDEVOPS_DISPATCH_LEASE_SESSION": "",
                       "AIDEVOPS_TEST_MODE": "1", "AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS": "1",
                       "DISPATCH_CLAIM_WINDOW": "0", "AIDEVOPS_DEVICE_ID": "test-device"}
                command = r'''
set -euo pipefail
source "$1/pr-checkpoint-continuation-helper.sh"
source "$1/headless-runtime-worker.sh"
source "$1/headless-runtime-worker-prepare.sh"
set_issue_status() { python3 "$CHECKPOINT_TEST_FILE" --set-issue "$@"; }
# Exercise dispatch metadata parsing without launching a real worker. Claim,
# lease transitions, exact-target fences and rollback below use the real helpers.
_prrts_dispatch_guarded() { return 0; }
_pcc_dispatch owner/repo "$HOME" 42 123 worker next-worker
[[ "$PCC_CHECKPOINT_ASSIGNEE" == worker && "$PCC_REVISION_APPROVAL" == "$CHECKPOINT_TEST_APPROVAL" ]]
_pcc_claim_revised_checkpoint owner/repo 42 "$PCC_HEAD_REF" "$PCC_HEAD_OID"
export WORKER_ISSUE_NUMBER=123 WORKER_REPO_SLUG=owner/repo WORKER_GITHUB_LOGIN=next-worker
export DISPATCH_REPO_SLUG=owner/repo
export AIDEVOPS_PR_REPAIR_NUMBER=42 AIDEVOPS_PR_REPAIR_LINKED_ISSUE=123 AIDEVOPS_PR_REPAIR_ISSUE_ASSIGNEE=next-worker
export AIDEVOPS_PR_CHECKPOINT_AUTHOR=worker AIDEVOPS_PR_REPAIR_HEAD_SHA="$PCC_HEAD_OID" AIDEVOPS_PR_REPAIR_HEAD_REF="$PCC_HEAD_REF"
if [[ "$CHECKPOINT_TEST_RENEW" == true ]]; then
    _hrw_renew_dispatch_prelaunch_lease "$AIDEVOPS_PR_CHECKPOINT_SESSION"
fi
_hrw_verify_dispatch_ownership 123 owner/repo
if [[ "$CHECKPOINT_TEST_READY" == true ]]; then
    "$1/dispatch-claim-helper.sh" transition ready 123 owner/repo "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$AIDEVOPS_PR_CHECKPOINT_SESSION"
    _hrw_verify_dispatch_ownership 123 owner/repo
    if _pcc_restore_transferred_ownership owner/repo 42; then exit 98; fi
    "$1/dispatch-claim-helper.sh" transition terminal 123 owner/repo "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$AIDEVOPS_PR_CHECKPOINT_SESSION"
else
    _pcc_restore_transferred_ownership owner/repo 42
    # GH#37735: no model ran and the exact head is unchanged. The real claim
    # producer must accept the same approval after the compensating release.
    "$1/dispatch-claim-helper.sh" claim-pr-checkpoint 123 owner/repo 42 "$PCC_HEAD_OID" "$PCC_HEAD_REF" next-worker "$AIDEVOPS_PR_CHECKPOINT_SESSION"
    exit 0
fi
if "$1/dispatch-claim-helper.sh" claim-pr-checkpoint 123 owner/repo 42 "$PCC_HEAD_OID" "$PCC_HEAD_REF" next-worker "$AIDEVOPS_PR_CHECKPOINT_SESSION"; then exit 99; fi
'''
                # The shell program is a fixed test literal, with only the trusted scripts directory as data.
                result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS)], env=env,  # nosec B603
                                        capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                restored = json.loads(state.read_text())["issue"]
                if build is fixture and not unassigned:
                    self.assertEqual(restored["assignees"], [{"login": "next-worker"}])
                    self.assertIn({"name": "status:in-progress"}, restored["labels"])
                else:
                    self.assertEqual(restored["assignees"], data["issue"]["assignees"])
                    self.assertEqual(restored["labels"], data["issue"]["labels"])

def released_successor_fixture():
    """Two historical attempts released before a new exact-revision approval."""
    data = fixture()
    data["comments"] = data["comments"][:2]
    for first, actor in ((4, "worker"), (10, "other-worker")):
        token = f"closed-{first}"
        session = f"issue-{first}"
        attempt = f"attempt:closed-{first}"
        lease = f"lease_token={token} session={session} attempt_id={attempt}"
        data["comments"].extend([
            comment(first, f"DISPATCH_CLAIM nonce={token} lease_token={token} "
                           f"runner={actor} session={session} phase=prelaunch", actor),
            comment(first + 1, f"DISPATCH_LEASE phase=prelaunch {lease}", actor),
            comment(first + 2, f"DISPATCH_LEASE phase=ready {lease}", actor),
            # Legacy releases omit the token; the unique ready attempt binds it.
            comment(first + 3, f"CLAIM_RELEASED reason=blocked runner={actor}", actor),
            comment(first + 4, f"DISPATCH_LEASE phase=terminal {lease} expires_at=0", actor),
        ])
    return data


class ReleasedSuccessorTests(unittest.TestCase):
    def approved(self, data):
        line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
        return {**data, "comments": data["comments"] + [
            comment(20, line, "maintainer", "OWNER")]}

    def test_template_binds_both_fully_closed_attempts(self):
        data = self.approved(released_successor_fixture())
        result = revision.validate(data)
        self.assertEqual(result["approval_id"], 20)
        history = result["released_successors"]
        self.assertEqual([item["release_id"] for item in history], [7, 13])
        self.assertEqual([item["runner"] for item in history], ["worker", "other-worker"])
        self.assertNotIn("lease_token", json.dumps(history))

    def test_old_approval_cannot_implicitly_ignore_history(self):
        data = released_successor_fixture()
        old = copy.deepcopy(fixture()["comments"][-1])
        old["id"] = 20
        with self.assertRaises(ValueError):
            revision.validate({**data, "comments": data["comments"] + [old]})

    def test_raw_attempt_ids_normalize_only_the_prefix(self):
        data = released_successor_fixture()
        data["comments"] = [{**c, "body": c["body"].replace("attempt:closed-", "closed-")}
                            for c in data["comments"]]
        approved = self.approved(data)
        history = revision.validate(approved)["released_successors"]
        self.assertEqual([item["attempt"] for item in history],
                         ["attempt:closed-4", "attempt:closed-10"])
        for case, value in {"different": "closed-other", "empty": "", "prefix_only": "attempt:"}.items():
            changed = copy.deepcopy(data)
            changed["comments"][-1]["body"] = changed["comments"][-1]["body"].replace(
                "attempt_id=closed-10", "attempt_id=" + value)
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.approved(changed)

    def test_stale_prelaunch_release_is_not_completed_history(self):
        data = released_successor_fixture()
        data["comments"] = [c for c in data["comments"] if c["id"] not in (12, 14)]
        data["comments"][-1]["body"] = (
            "CLAIM_RELEASED reason=stale_assignment_reset runner=other-worker")
        with self.assertRaises(ValueError):
            self.approved(data)

    def test_open_or_ambiguous_attempts_cannot_generate_approval(self):
        mutations = {
            "no_release": lambda d: d["comments"].pop(-2),
            "no_terminal": lambda d: d["comments"].pop(-1),
            "no_ready": lambda d: d["comments"].pop(-3),
            "wrong_actor": lambda d: d["comments"][-1]["user"].update(login="stranger"),
            "wrong_token": lambda d: self.change_terminal(d, "closed-10"),
            "wrong_session": lambda d: self.change_terminal(d, "issue-10"),
            "wrong_attempt": lambda d: self.change_terminal(d, "attempt:closed-10"),
            "edited": lambda d: d["comments"][-2].update(updated_at="2026-09-05T12:01:00Z"),
            "interactive": lambda d: d["comments"].append(
                comment(16, "Interactive session claimed", "maintainer")),
            "overlap": lambda d: d["comments"].insert(3, comment(4.5,
                "DISPATCH_CLAIM nonce=overlap lease_token=overlap runner=other-worker session=other",
                "other-worker")),
        }
        for case, mutate in mutations.items():
            data = released_successor_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.approved(data)

    def change_terminal(self, data, field):
        data["comments"][-1]["body"] = data["comments"][-1]["body"].replace(field, "wrong")

    def test_bound_history_changes_and_new_events_still_block(self):
        for case in ("edited_release", "remove_history", "alter_history", "post_approval_claim",
                     "approval_coordination"):
            data = self.approved(released_successor_fixture())
            if case == "edited_release":
                data["comments"][-3]["updated_at"] = "2026-09-05T12:01:00Z"
            elif case == "approval_coordination":
                data["comments"][-1]["body"] += "\nInteractive session claimed"
            elif case == "post_approval_claim":
                data["comments"].append(comment(21, "DISPATCH_CLAIM nonce=late "
                    "lease_token=late runner=worker session=late", "worker"))
            else:
                approval = json.loads(data["comments"][-1]["body"][len(revision.PREFIX):])
                if case == "remove_history":
                    del approval["released_successors"]
                else:
                    approval["released_successors"][0]["terminal_id"] = 999
                data["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(data)

    def test_approved_history_retains_live_claim_fencing(self):
        data = self.approved(released_successor_fixture())
        data.update(lease="current", session="checkpoint-42", assignee="next-worker", claiming=True)
        data["comments"].append(comment(21, "DISPATCH_CLAIM nonce=current lease_token=current "
            "runner=next-worker checkpoint_approval=20 session=checkpoint-42 expires_at=1788620400",
            "next-worker"))
        self.assertEqual(revision.validate(data)["approval_id"], 20)
        with self.assertRaises(ValueError):
            revision.validate({**data, "lease": "wrong"})

    def test_immediate_release_without_a_lease_is_controlled_rejection(self):
        data = released_successor_fixture()
        data["comments"] = data["comments"][:3] + [data["comments"][5]]
        with self.assertRaises(ValueError):
            self.approved(data)

    def test_live_claim_cannot_reuse_a_historical_token(self):
        for token in ("closed-4", "closed-10"):
            data = self.approved(released_successor_fixture())
            data.update(lease=token, session="checkpoint-42", assignee="next-worker", claiming=True)
            data["comments"].append(comment(21, f"DISPATCH_CLAIM nonce={token} lease_token={token} "
                "runner=next-worker checkpoint_approval=20 session=checkpoint-42 expires_at=1788620400",
                "next-worker"))
            with self.subTest(token=token), self.assertRaises(ValueError):
                revision.validate(data)


class AutomaticAdmissionTests(AutomaticBindingCases, unittest.TestCase):
    admission = admission
    revision = revision
    comment = staticmethod(comment)
    bash = BASH
    scripts = SCRIPTS

    def test_revision_claim_rejects_ambiguous_mode(self):
        data = {"lease": "revision-claim", "session": "checkpoint-42", "assignee": "worker"}
        line = ("DISPATCH_CLAIM nonce=revision-claim lease_token=revision-claim runner=worker "
                "session=checkpoint-42 checkpoint_approval=3")
        claim = comment(4, line)
        self.assertTrue(own_claim_matches(data, 3, claim, line, fields(line)))
        for mode in ("revision", "automatic", "unknown"):
            candidate = line + " checkpoint_mode=" + mode
            self.assertEqual(own_claim_matches(data, 3, claim, candidate, fields(candidate)), mode == "revision")

    def claimed(self):
        data = fixture()
        data.update(comments=[], session="checkpoint-42", device="test-device", claiming=True)
        snapshot = admission.admission(data)["snapshot"]
        claim = comment(4, "DISPATCH_CLAIM nonce=automatic lease_token=automatic runner=worker "
                        "session=checkpoint-42 device=test-device phase=prelaunch expires_at=1788616800 "
                        "checkpoint_mode=automatic checkpoint_owner=worker checkpoint_status=in-review "
                        "checkpoint_snapshot=" + snapshot)
        claim["_release_body_unedited"] = True
        data.update(comments=[claim], lease="automatic")
        return data

    def test_ready_attempt_requires_exact_runtime_identity(self):
        data = self.claimed()
        data.update(claiming=False, attempt="runtime-one")
        data["issue"]["labels"][1]["name"] = "status:in-progress"
        ready = comment(5, "DISPATCH_LEASE phase=ready lease_token=automatic session=checkpoint-42 "
                        "device=test-device attempt_id=runtime-one expires_at=1788616800")
        ready["_release_body_unedited"] = True
        data["comments"].append(ready)
        self.assertEqual(admission.admission(data)["claim_id"], 4)
        for attempt in ("runtime-two", "", "unknown"):
            with self.subTest(attempt=attempt), self.assertRaises(ValueError):
                admission.admission({**data, "attempt": attempt})
        with self.assertRaises(ValueError):
            admission.admission({**data, "require_prelaunch": True})

    def test_automatic_handoff_runtime_and_failed_launch_cleanup(self):
        for unassigned, capability, ready in ((False, False, False), (True, False, False),
                                             (True, True, False), (False, False, True)):
            with self.subTest(unassigned=unassigned, capability=capability, ready=ready), tempfile.TemporaryDirectory() as root:
                data = fixture()
                data["issue"]["labels"].append({"name": "auto-dispatch"})
                data["pr"]["title"] = "Preserved automatic checkpoint"
                data["comments"] = data["comments"][:2]
                reason = ("blocked runner=worker\n\nTerminal blocker: reason=runner_capability_unmet missing=test"
                          if capability else "worker_draft_checkpoint runner=worker")
                data["comments"][1]["body"] = "CLAIM_RELEASED reason=" + reason
                if unassigned:
                    data["issue"]["assignees"] = []
                    data["issue"]["labels"][1]["name"] = "status:available"
                for c in data["comments"]:
                    c["created_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
                state = pathlib.Path(root) / "state.json"
                state.write_text(json.dumps(data))
                gh = pathlib.Path(root) / "gh"
                gh.write_text('#!/usr/bin/env bash\nexec python3 "$CHECKPOINT_TEST_FILE" --gh "$@"\n')
                gh.chmod(0o700)
                env = {**os.environ, "PATH": root + os.pathsep + os.environ["PATH"], "HOME": root,
                       "CHECKPOINT_TEST_FILE": str(pathlib.Path(__file__).with_name("checkpoint_github_fixture.py")),
                       "CHECKPOINT_TEST_STATE": str(state), "AIDEVOPS_TEST_MODE": "1",
                       "CHECKPOINT_TEST_RELEASED": str(unassigned).lower(),
                       "CHECKPOINT_TEST_READY": str(ready).lower(), "AIDEVOPS_ATTEMPT_ID": "automatic-fixture",
                       "AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS": "1", "DISPATCH_CLAIM_WINDOW": "0",
                       "AIDEVOPS_DEVICE_ID": "test-device", "AIDEVOPS_DISPATCH_LEASE_SESSION": "unrelated-parent-session"}
                command = r'''
set -euo pipefail
source "$1/pr-checkpoint-continuation-helper.sh"
source "$1/headless-runtime-worker-prepare.sh"
set_issue_status() { python3 "$CHECKPOINT_TEST_FILE" --set-issue "$@"; }
_prrts_dispatch_guarded() { return 0; }
PCC_ALLOW_RELEASED="$CHECKPOINT_TEST_RELEASED"
_pcc_dispatch owner/repo "$HOME" 42 123 worker next-worker
[[ "$PCC_REVISION_APPROVAL" == 0 ]]
_prrts_prelaunch_target_fence owner/repo 42 "$PCC_HEAD_REF" "$PCC_HEAD_OID"
[[ "$AIDEVOPS_DISPATCH_LEASE_SESSION" == "$AIDEVOPS_PR_CHECKPOINT_SESSION" && "$AIDEVOPS_DISPATCH_LEASE_DEVICE" == test-device ]]
export WORKER_ISSUE_NUMBER=123 WORKER_REPO_SLUG=owner/repo WORKER_GITHUB_LOGIN=next-worker
export DISPATCH_REPO_SLUG=owner/repo
export AIDEVOPS_PR_REPAIR_NUMBER=42 AIDEVOPS_PR_REPAIR_LINKED_ISSUE=123 AIDEVOPS_PR_REPAIR_ISSUE_ASSIGNEE=next-worker
export AIDEVOPS_PR_CHECKPOINT_AUTHOR=worker AIDEVOPS_PR_REPAIR_HEAD_SHA="$PCC_HEAD_OID" AIDEVOPS_PR_REPAIR_HEAD_REF="$PCC_HEAD_REF"
_hrw_verify_dispatch_ownership
# Explicit revision admission cannot become a metadata-only legacy check.
if env -u AIDEVOPS_PR_CHECKPOINT_SESSION AIDEVOPS_PR_CHECKPOINT_ADMISSION_MODE=revision \
    "$1/dispatch-claim-helper.sh" verify-pr-checkpoint-target 42 owner/repo "$PCC_HEAD_OID" "$PCC_HEAD_REF" 123 next-worker worker; then exit 97; fi
# A repeated producer fence verifies the same claim rather than minting another.
_prrts_prelaunch_target_fence owner/repo 42 "$PCC_HEAD_REF" "$PCC_HEAD_OID"
if [[ "$CHECKPOINT_TEST_READY" == true ]]; then
    "$1/dispatch-claim-helper.sh" transition ready 123 owner/repo "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$AIDEVOPS_PR_CHECKPOINT_SESSION"
    _hrw_verify_dispatch_ownership
    # Once ready, a producer must not roll back an attempt that may be running.
    if _pcc_restore_transferred_ownership owner/repo 42; then exit 98; fi
    "$1/dispatch-claim-helper.sh" transition terminal 123 owner/repo "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$AIDEVOPS_PR_CHECKPOINT_SESSION"
else
    _pcc_restore_transferred_ownership owner/repo 42
fi
if _hrw_verify_dispatch_ownership; then exit 99; fi
'''
                result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS)], env=env,  # nosec B603
                                        capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                saved = json.loads(state.read_text())
                if ready:
                    self.assertEqual(saved["issue"]["assignees"], [{"login": "next-worker"}])
                    self.assertIn({"name": "status:in-progress"}, saved["issue"]["labels"])
                else:
                    self.assertEqual(saved["issue"]["assignees"], data["issue"]["assignees"])
                    self.assertCountEqual(saved["issue"]["labels"], data["issue"]["labels"])
                claims = [c for c in saved["comments"] if "DISPATCH_CLAIM " in c["body"]]
                self.assertEqual(len(claims), 1)
                self.assertIn("checkpoint_mode=automatic", claims[0]["body"])
                self.assertNotIn("CHECKPOINT_CONTINUATION_APPROVED", json.dumps(saved))


class ProgressTests(ProgressCases, unittest.TestCase):
    queue = queue


if __name__ == "__main__":
    unittest.main()
