#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Launch-failure cases discovered through the existing checkpoint runner.

The entry point supplies fixture, revision, bash and scripts attributes.
"""

import datetime as dt
import json
import os
import pathlib
import subprocess  # nosec B404 — executes fixed offline fixture programs only
import tempfile


class LaunchFailureCases:
    def test_claim_only_launch_failure_compensation_fences(self):
        transfer_failures = ("before", "status", "add", "remove")
        for drift in ("none", "head", "owner", "human", "launched", *transfer_failures,
                      "transfer-before", "transfer-status", "transfer-owner",
                      "fail-release-before", "fail-release-after", "fail-terminal-before", "fail-terminal-after"):
            with self.subTest(drift=drift), tempfile.TemporaryDirectory() as root:
                data = self.fixture()
                # Discovery requires a non-empty title in its TSV target row.
                data["pr"]["title"] = "Checkpoint compensation"
                data["issue"]["title"] = "Checkpoint compensation"
                if drift in transfer_failures:
                    data["transfer_failure"] = drift
                for c in data["comments"]:
                    c["created_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
                state = pathlib.Path(root) / "state.json"
                state.write_text(json.dumps(data))
                gh = pathlib.Path(root) / "gh"
                gh.write_text('#!/usr/bin/env bash\nexec python3 "$CHECKPOINT_TEST_FILE" --gh "$@"\n')
                gh.chmod(0o700)
                # Pin the state dir: the aggregate shell suite exports its own,
                # which would leak compensation files across subtests.
                env = {**os.environ, "PATH": root + os.pathsep + os.environ["PATH"], "HOME": root,
                       "AIDEVOPS_PR_CHECKPOINT_CONTINUATION_STATE_DIR": str(pathlib.Path(root) / "state"),
                       "CHECKPOINT_TEST_FILE": str(self.scripts / "tests" / "checkpoint_github_fixture.py"),
                       "CHECKPOINT_TEST_STATE": str(state), "CHECKPOINT_TEST_DRIFT": drift,
                       "AIDEVOPS_DISPATCH_LEASE_SESSION": "", "AIDEVOPS_TEST_MODE": "1",
                       "AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS": "1", "DISPATCH_CLAIM_WINDOW": "0",
                       "AIDEVOPS_DEVICE_ID": "test-device"}
                command = r'''
set -euo pipefail
source "$1/pr-checkpoint-continuation-helper.sh"
set_issue_status() { python3 "$CHECKPOINT_TEST_FILE" --set-issue "$@"; }
_prrts_dispatch_guarded() {
    _pcc_claim_revised_checkpoint owner/repo 42 "$PCC_HEAD_REF" "$PCC_HEAD_OID" || return 13
    python3 "$CHECKPOINT_TEST_FILE" --drift "$CHECKPOINT_TEST_DRIFT"
    if [[ "$CHECKPOINT_TEST_DRIFT" == launched ]]; then PRRTS_WORKER_LAUNCH_STARTED=1; fi
    return 13
}
if _pcc_dispatch owner/repo "$HOME" 42 123 worker next-worker; then exit 99; fi
'''
                result = subprocess.run([self.bash, "-c", command, "test", str(self.scripts)], env=env,  # nosec B603
                                        capture_output=True, text=True, timeout=30, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("launch failed rc=13", result.stdout, result.stderr)
                if drift.startswith("fail-"):
                    pending = list(pathlib.Path(root).rglob("*.compensation.json"))
                    self.assertEqual(len(pending), 1)
                    # A new process has no claim globals. Recover only the saved
                    # exact episode, checking uncertain POSTs before retrying.
                    retry = 'source "$1/pr-checkpoint-continuation-helper.sh"; _pcc_retry_compensation owner/repo 42'
                    if drift == "fail-release-before":
                        self.assert_compensation_retry_fences(state, pending[0], env, retry)
                    result = subprocess.run([self.bash, "-c", retry, "test", str(self.scripts)], env=env,  # nosec B603
                                            capture_output=True, text=True, timeout=30, check=False)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(pending[0].exists())
                saved = json.loads(state.read_text())
                releases = [c for c in saved["comments"] if c["body"].startswith("CLAIM_RELEASED reason=worker_not_launched")]
                terminals = [c for c in saved["comments"] if c["body"].startswith("DISPATCH_LEASE phase=terminal")]
                if drift == "none" or drift in transfer_failures or drift.startswith(("transfer-", "fail-")):
                    self.assertEqual(saved["issue"], data["issue"] | {"updated_at": saved["issue"]["updated_at"]})
                    self.assertEqual(len(releases), 1)
                    self.assertEqual(len(terminals), 1)
                    self.assertLess(releases[0]["id"], terminals[0]["id"])
                    self.assertEqual(self.revision.validate({**saved, "assignee": "next-worker",
                                     "now": dt.datetime.now(dt.timezone.utc).timestamp()})["approval_id"], 3)
                else:
                    self.assertEqual(releases, [])
                    self.assertEqual(terminals, [])
                    owner = "replacement-owner" if drift == "owner" else "next-worker"
                    self.assertEqual(saved["issue"]["assignees"], [{"login": owner}])
                    self.assertIn({"name": "status:in-progress"}, saved["issue"]["labels"])

    def assert_compensation_retry_fences(self, state, pending, env, retry):
        original = state.read_text()
        for change in ("head", "owner", "human", "claim-edit"):
            changed = json.loads(original)
            if change == "head":
                changed["pr"]["headRefOid"] = "2" * 40
            elif change == "owner":
                changed["issue"]["assignees"] = [{"login": "replacement-owner"}]
            elif change == "human":
                changed["comments"].append(self.comment(999, "Interactive session claimed", "maintainer", "OWNER"))
            else:
                changed["comments"][-1]["body"] += " edited"
            state.write_text(json.dumps(changed))
            result = subprocess.run([self.bash, "-c", retry, "test", str(self.scripts)], env=env,  # nosec B603
                                    capture_output=True, text=True, timeout=30, check=False)
            self.assertNotEqual(result.returncode, 0, change)
            self.assertTrue(pending.exists(), change)
            self.assertEqual(json.loads(state.read_text()), changed, change)
        state.write_text(original)

    def test_detached_launch_failure_reasons_and_activation_fence(self):
        command = r'''
set -euo pipefail
source "$1/pr-review-thread-response-launch.sh"
_prrts_log() { return 0; }
_hrw_create_detached_log() { return 1; }
if _prrts_launch_detached_worker owner/repo 42 pid mode true; then exit 91; fi
[[ "$PRRTS_WORKTREE_FAILURE_REASON" == detached_log_creation_failed ]]
_hrw_create_detached_log() { printf '%s' /dev/null; return 0; }
systemd_scope_available() { return 0; }
systemd_scope_launch() { return 1; }
if _prrts_launch_detached_worker owner/repo 42 pid mode true; then exit 92; fi
[[ "$PRRTS_WORKTREE_FAILURE_REASON" == worker_scope_launch_failed ]]
systemd_scope_available() { return 1; }
INVOCATION_ID=test
if _prrts_launch_detached_worker owner/repo 42 pid mode true; then exit 93; fi
[[ "$PRRTS_WORKTREE_FAILURE_REASON" == worker_scope_unavailable ]]
_prrts_launch_detached_worker() { printf -v "$3" '%s' 12345; return 0; }
_prrts_activate_global_capacity() { return 1; }
_prrts_release_global_capacity() { return 0; }
kill() { return 0; }
PRRTS_WORKER_LAUNCH_STARTED=0
if _prrts_launch_reserved_worker owner/repo 42 worktree session attempt reservation true; then exit 94; fi
[[ "$PRRTS_WORKTREE_FAILURE_REASON" == global_worker_reservation_activation_failed ]]
[[ "$PRRTS_WORKER_LAUNCH_STARTED" == 1 ]]
'''
        result = subprocess.run([self.bash, "-c", command, "test", str(self.scripts)],  # nosec B603
                                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
