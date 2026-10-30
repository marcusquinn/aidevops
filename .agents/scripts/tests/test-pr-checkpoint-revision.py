#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mocked GitHub regression cases for corrected checkpoint authorization."""

import copy
import datetime as dt
import hashlib
import importlib.util
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
from pr_checkpoint_events import EVENTS
import integration_recovery as recovery


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


revision = load("revision", "pr-checkpoint-revision.py")
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


def insert_renewed_attempt(data):
    """Insert a same-actor ready lease for a different attempt before the release."""
    renewed = copy.deepcopy(data["comments"][0])
    renewed.update(id=1.5, body=renewed["body"].replace("original", "other"))
    data["comments"].insert(1, renewed)


class RevisionTests(unittest.TestCase):
    def test_released_revised(self):
        self.assertEqual(revision.validate(fixture())["approval_id"], 3)

    def test_legacy_release_and_ambiguous_attempt(self):
        data = fixture()
        data["comments"][1]["body"] = "CLAIM_RELEASED reason=blocked runner=worker"
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        data["comments"].insert(0, comment(0, "DISPATCH_LEASE phase=ready lease_token=other attempt_id=attempt:original"))
        with self.assertRaises(ValueError):
            revision.validate(data)

    def test_wrong_envelopes(self):
        for key, value in [("repo", "other/repo"), ("issue", 124), ("pr", 43),
                           ("head", "2" * 40), ("ref", "other"), ("runner", "other"),
                           ("attempt", "attempt:other"), ("release_id", 99), ("brief_sha256", "bad")]:
            with self.subTest(key=key):
                data = fixture()
                approval = json.loads(data["comments"][-1]["body"][len(revision.PREFIX):])
                approval[key] = value
                data["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
                with self.assertRaises(ValueError):
                    revision.validate(data)

    def test_wrong_actor_stale_edited_and_new_owner(self):
        for case in ("actor", "stale", "edited", "owner", "revision", "head", "release_actor"):
            data = fixture()
            if case == "actor":
                data["comments"][-1]["author_association"] = "NONE"
            elif case == "stale":
                data["now"] += 86400
            elif case == "edited":
                data["comments"][-1]["updated_at"] = "2026-09-05T12:01:00Z"
            elif case == "owner":
                data["issue"]["assignees"] = [{"login": "new-owner"}]
            elif case == "revision":
                data["issue"]["body"] += " changed"
            elif case == "head":
                data["pr"]["headRefOid"] = "2" * 40
            else:
                data["comments"][1]["user"]["login"] = "other"
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(data)

    def test_template_refuses_releases_dispatch_approved_rejects(self):
        # GH#33997: never print an approval that dispatch-approved cannot accept.
        data = fixture()
        data["comments"] = data["comments"][:2]
        template = {**data, "release_id": 2, "attempt": "attempt:original"}
        line = revision.template(template)
        approved = {**fixture(), "comments": template["comments"] + [
            comment(3, line, "maintainer", "OWNER")]}
        self.assertEqual(revision.validate(approved)["approval_id"], 3)
        for reason in ("worker_draft_checkpoint", "crash_during_execution", "worker_failed"):
            refused = copy.deepcopy(template)
            refused["comments"][1]["body"] = f"CLAIM_RELEASED reason={reason} runner=worker"
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                revision.template(refused)
        for key, value in (("attempt", "attempt:other"), ("release_id", 99)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                revision.template({**template, key: value})

    def test_unassigned_and_newer_coordination(self):
        data = fixture()
        data["issue"]["assignees"] = []
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        for event in EVENTS:
            with self.subTest(event=event), self.assertRaises(ValueError):
                revision.validate({**data, "comments": data["comments"] + [comment(4, event + "new-owner")]})

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

    def test_shell_predicate_preserves_holds_and_linkage(self):
        data = fixture()
        # Supply current wall time for the shell boundary, avoiding date-dependent fixtures.
        for c in data["comments"]:
            c["created_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        command = ('source "$1/pr-checkpoint-target-lib.sh"; '
                   'gh() { [[ "$*" == "api repos/owner/repo/collaborators/maintainer/permission --jq .permission" ]] || return 90; '
                   'printf "%s" "${TEST_PERMISSION:-write}"; }; '
                   '_pr_checkpoint_revised_target "$2" "$3" "$4" "$5" worker')
        def run(candidate):
            # Fixed Bash source and locally constructed JSON are positional data, never shell source.
            return subprocess.run([BASH, "-c", command, "test", str(SCRIPTS), candidate["repo"],  # nosec B603
                                   json.dumps(candidate["pr"]), json.dumps(candidate["issue"]),
                                   json.dumps(candidate["comments"])], capture_output=True, check=False).returncode
        self.assertEqual(run(data), 0)
        for label in ("hold-for-review", "needs-maintainer-review", "no-auto-dispatch", "persistent", "blocked"):
            changed = copy.deepcopy(data)
            changed["issue"]["labels"].append({"name": label})
            self.assertNotEqual(run(changed), 0)
        for body in ("For #1234", "mentions #123", "For #123 and #124"):
            changed = copy.deepcopy(data)
            changed["pr"]["body"] = body
            self.assertNotEqual(run(changed), 0)

    def test_claim_handoff_prelaunch_ready_and_rollback(self):
        # (unassigned, fixture builder, needs a generated approval for its history)
        cases = ((False, fixture, False), (True, fixture, False),
                 (True, released_successor_fixture, True),
                 (False, completed_release_fixture, True), (True, completed_release_fixture, True))
        for unassigned, build, approve in cases:
            with self.subTest(unassigned=unassigned, fixture=build.__name__), tempfile.TemporaryDirectory() as root:
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
                    data["issue"]["labels"][1] = {"name": "status:available"}
                for c in data["comments"]:
                    c["created_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
                state = pathlib.Path(root) / "state.json"
                state.write_text(json.dumps(data))
                gh = pathlib.Path(root) / "gh"
                gh.write_text('#!/usr/bin/env bash\nexec python3 "$CHECKPOINT_TEST_FILE" --gh "$@"\n')
                gh.chmod(0o700)
                env = {**os.environ, "PATH": root + os.pathsep + os.environ["PATH"], "HOME": root,
                       "CHECKPOINT_TEST_FILE": str(pathlib.Path(__file__).with_name("checkpoint_github_fixture.py")), "CHECKPOINT_TEST_STATE": str(state),
                       "CHECKPOINT_TEST_APPROVAL": str(approval_id),
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
_hrw_renew_dispatch_prelaunch_lease "$AIDEVOPS_PR_CHECKPOINT_SESSION"
"$1/dispatch-claim-helper.sh" transition ready 123 owner/repo "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$AIDEVOPS_PR_CHECKPOINT_SESSION"
_hrw_verify_dispatch_ownership 123 owner/repo
_pcc_restore_transferred_ownership owner/repo 42
if "$1/dispatch-claim-helper.sh" claim-pr-checkpoint 123 owner/repo 42 "$PCC_HEAD_OID" "$PCC_HEAD_REF" next-worker "$AIDEVOPS_PR_CHECKPOINT_SESSION"; then exit 99; fi
'''
                # The shell program is a fixed test literal, with only the trusted scripts directory as data.
                result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS)], env=env,  # nosec B603
                                        capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                restored = json.loads(state.read_text())["issue"]
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


class ProgressTests(unittest.TestCase):
    def test_comments_do_not_reset_progress(self):
        now = dt.datetime.fromisoformat("2026-09-05T13:00:00+00:00")
        issue = {"number": 123, "createdAt": "2026-09-05T10:00:00Z", "updatedAt": "2026-09-05T12:59:59Z"}
        queue._run_gh_json = lambda args: [{"event": "commented", "created_at": issue["updatedAt"]}]
        self.assertEqual(queue._durable_progress_age("owner/repo", issue, now), 180)
        aggregate = queue._empty_aggregate()
        queue._count_durable_progress(aggregate, "owner/repo", issue, now)
        self.assertEqual(aggregate["no_durable_progress_hour"], 1)
        for labels in ([{"name": "persistent"}], [{"name": "needs-maintainer-permissions"}]):
            aggregate = queue._empty_aggregate()
            queue._count_durable_progress(aggregate, "owner/repo", {**issue, "labels": labels}, now)
            self.assertEqual(aggregate["no_durable_progress_hour"], 0)
        queue._run_gh_json = lambda args: None
        self.assertIsNone(queue._durable_progress_age("owner/repo", issue, now))

    def test_open_linked_pr_preserves_owned_progress(self):
        now = dt.datetime.fromisoformat("2026-09-05T13:00:00+00:00")
        issue = {"number": 123, "createdAt": "2026-09-05T10:00:00Z", "labels": []}

        def run_gh(args):
            if args[1:3] == ["api", "repos/owner/repo/issues/123/timeline?per_page=100"]:
                return [{"event": "cross-referenced", "source": {"issue": {
                    "number": 42, "pull_request": {"url": "https://example.invalid/pr/42"},
                    "repository_url": "https://api.github.com/repos/owner/repo"}}}]
            if args[1:3] == ["pr", "view"]:
                return {"state": "OPEN", "createdAt": "2026-09-05T10:30:00Z",
                        "commits": [], "statusCheckRollup": []}
            return None

        queue._run_gh_json = run_gh
        aggregate = queue._empty_aggregate()
        queue._count_durable_progress(aggregate, "owner/repo", issue, now)
        self.assertEqual(aggregate["no_durable_progress_hour"], 0)
        self.assertEqual(aggregate["oldest_durable_progress_age_min"], 0)


if __name__ == "__main__":
    unittest.main()
