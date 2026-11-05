#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Existing envelope assertions shared by the checkpoint unittest entry point.

The entry point supplies its fixture and validators as class attributes, keeping
test discovery and all cases in the existing runner without circular imports.
"""

import copy
import datetime as dt
import json
import subprocess  # nosec B404 — fixed offline fixture program only

from pr_checkpoint_events import EVENTS


class RevisionEnvelopeCases:
    def test_wrong_envelopes(self):
        for key, value in [("repo", "other/repo"), ("issue", 124), ("pr", 43),
                           ("head", "2" * 40), ("ref", "other"), ("runner", "other"),
                           ("attempt", "attempt:other"), ("release_id", 99), ("brief_sha256", "bad")]:
            with self.subTest(key=key):
                data = self.fixture()
                approval = json.loads(data["comments"][-1]["body"][len(self.revision.PREFIX):])
                approval[key] = value
                data["comments"][-1]["body"] = self.revision.PREFIX + json.dumps(approval)
                with self.assertRaises(ValueError):
                    self.revision.validate(data)

    def test_wrong_actor_stale_edited_and_new_owner(self):
        for case in ("actor", "stale", "edited", "owner", "revision", "head", "release_actor"):
            data = self.fixture()
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
                self.revision.validate(data)

    def test_template_refuses_releases_dispatch_approved_rejects(self):
        # GH#33997: never print an approval that dispatch-approved cannot accept.
        data = self.fixture()
        data["comments"] = data["comments"][:2]
        template = {**data, "release_id": 2, "attempt": "attempt:original"}
        line = self.revision.template(template)
        approved = {**self.fixture(), "comments": template["comments"] + [
            self.comment(3, line, "maintainer", "OWNER")]}
        self.assertEqual(self.revision.validate(approved)["approval_id"], 3)
        for reason in ("worker_draft_checkpoint", "crash_during_execution", "worker_failed"):
            refused = copy.deepcopy(template)
            refused["comments"][1]["body"] = f"CLAIM_RELEASED reason={reason} runner=worker"
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                self.revision.template(refused)
        for key, value in (("attempt", "attempt:other"), ("release_id", 99)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.revision.template({**template, key: value})


class AutomaticBindingCases:
    def test_optional_claim_arguments_keep_nonce_position(self):
        command = r'''
set -euo pipefail
source "$1/dispatch-claim-automatic-checkpoint.sh"
shift
_resolve_runner() { printf runner; return 0; }
aidevops_can_manage_repo_issue_state() { return 0; }
_dch_automatic_checkpoint_snapshot() {
    [[ "$#" == 10 || "$#" == 11 ]] || return 1
    [[ "${10}" == false || "${10}" == true ]] || return 1
    if [[ "$#" == 11 ]]; then [[ "${11}" == testnonce ]] || return 1; fi
    printf '%s' '{"snapshot":"same","previous_status":"in-review"}'
    return 0
}
_generate_nonce() { printf testnonce; return 0; }
_post_claim() { printf 123; return 0; }
_now_utc() { printf 2026-11-05; return 0; }
sleep() { return 0; }
_fetch_claims() { printf '%s' '[{"nonce":"testnonce","lease_expires_at":123}]'; return 0; }
_resolve_claim_race_result() { return 0; }
_resolve_device_id() { printf fixture; return 0; }
DISPATCH_CLAIM_WINDOW=0
cmd_claim_automatic_pr_checkpoint 123 owner/repo 42 1111111111111111111111111111111111111111 worker/123 runner checkpoint-42 runner runner "$@"
'''
        for args in ([], ["false"], ["true"], ["false", "unexpected"]):
            with self.subTest(args=args):
                result = subprocess.run([self.bash, "-c", command, "test", str(self.scripts), *args],  # nosec B603
                                        capture_output=True, text=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_snapshot_and_runtime_binding(self):
        data = self.claimed()
        self.assertEqual(self.admission.admission(data)["claim_id"], 4)
        for field, value in (("device", "foreign"), ("session", "foreign"), ("now", 1788616801)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.admission.admission({**data, field: value})
        for key, value in (("headRefOid", "2" * 40), ("headRefName", "other")):
            changed = copy.deepcopy(data)
            changed["pr"][key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.admission.admission(changed)
        changed = copy.deepcopy(data)
        changed["issue"]["body"] += " revised"
        with self.assertRaises(ValueError):
            self.admission.admission(changed)
        data["claiming"] = False
        with self.assertRaises(ValueError):
            self.admission.admission(data)
        data["issue"]["labels"][1]["name"] = "status:in-progress"
        self.assertEqual(self.admission.admission(data)["claim_id"], 4)

    def test_later_coordination_and_edit_evidence(self):
        for event in EVENTS:
            data = self.claimed()
            later = self.comment(5, event + "foreign", "other")
            later["_release_body_unedited"] = True
            data["comments"].append(later)
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.admission.admission(data)
        for evidence in (False, None):
            data = self.claimed()
            data["comments"][0]["_release_body_unedited"] = evidence
            with self.subTest(evidence=evidence), self.assertRaises(ValueError):
                self.admission.admission(data)

    def test_recorded_revision_never_downgrades_to_automatic(self):
        for association in ("OWNER", "MEMBER", "NONE", "CONTRIBUTOR"):
            data = self.claimed()
            data["trusted_logins"] = ["maintainer"]
            data["comments"].append(self.comment(5, self.revision.PREFIX + "expired-or-invalid", "maintainer", association))
            with self.subTest(association=association), self.assertRaises(ValueError):
                self.admission.admission(data)


class ProgressCases:
    def test_comments_do_not_reset_progress(self):
        now = dt.datetime.fromisoformat("2026-09-05T13:00:00+00:00")
        issue = {"number": 123, "createdAt": "2026-09-05T10:00:00Z", "updatedAt": "2026-09-05T12:59:59Z"}
        self.queue._run_gh_json = lambda args: [{"event": "commented", "created_at": issue["updatedAt"]}]
        self.assertEqual(self.queue._durable_progress_age("owner/repo", issue, now), 180)
        aggregate = self.queue._empty_aggregate()
        self.queue._count_durable_progress(aggregate, "owner/repo", issue, now)
        self.assertEqual(aggregate["no_durable_progress_hour"], 1)
        for labels in ([{"name": "persistent"}], [{"name": "needs-maintainer-permissions"}]):
            aggregate = self.queue._empty_aggregate()
            self.queue._count_durable_progress(aggregate, "owner/repo", {**issue, "labels": labels}, now)
            self.assertEqual(aggregate["no_durable_progress_hour"], 0)
        self.queue._run_gh_json = lambda args: None
        self.assertIsNone(self.queue._durable_progress_age("owner/repo", issue, now))

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

        self.queue._run_gh_json = run_gh
        aggregate = self.queue._empty_aggregate()
        self.queue._count_durable_progress(aggregate, "owner/repo", issue, now)
        self.assertEqual(aggregate["no_durable_progress_hour"], 0)
        self.assertEqual(aggregate["oldest_durable_progress_age_min"], 0)
