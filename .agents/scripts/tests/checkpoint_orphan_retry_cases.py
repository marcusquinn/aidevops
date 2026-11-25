#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Automatic checkpoint retry cases discovered through the existing checkpoint runner.

The entry point supplies fixture, comment, bash and scripts attributes.
"""

import datetime as dt
import json
import os
import pathlib
import subprocess  # nosec B404 — executes fixed offline fixture programs only
import tempfile

RETRY_COMMAND = r'''
set -euo pipefail
source "$1/pr-checkpoint-continuation-helper.sh"
source "$1/headless-runtime-worker-prepare.sh"
set_issue_status() { python3 "$CHECKPOINT_TEST_FILE" --set-issue "$@"; }
_prrts_dispatch_guarded() { return 0; }
PCC_ALLOW_RELEASED=true
[[ "$(_pcc_session_key owner/repo 42)" == pr-checkpoint-continuation-owner-repo-42 ]]
_pcc_dispatch owner/repo "$HOME" 42 123 worker next-worker >/dev/null
_prrts_prelaunch_target_fence owner/repo 42 "$PCC_HEAD_REF" "$PCC_HEAD_OID"
_pcc_restore_transferred_ownership owner/repo 42
'''


def _stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


class OrphanRetryCases:
    def _orphan_claim(self, now):
        # The runner's own expired, never-launched automatic claim from a prior attempt.
        fields = {"nonce": "oldnonce", "runner": "next-worker", "ts": _stamp(now - dt.timedelta(minutes=5)),
                  "max_age_s": "1800", "lease_" + "token": "oldnonce", "device": "test-device",
                  "session": "pr-checkpoint-continuation-owner-repo-42", "phase": "prelaunch",
                  "expires_at": str(int((now - dt.timedelta(minutes=3)).timestamp())),
                  "checkpoint_mode": "automatic", "checkpoint_snapshot": "old",
                  "checkpoint_owner": "none", "checkpoint_status": "available"}
        old = self.comment(3, "DISPATCH_CLAIM " + " ".join(f"{k}={v}" for k, v in fields.items()), "next-worker")
        old["created_at"] = fields["ts"]
        return old

    def test_retry_after_own_never_launched_claim_transfers_and_compensates(self):
        # GH#40297/GH#40373: a retry from the same device and per-PR session must
        # release its own expired, never-launched claim before claiming again.
        with tempfile.TemporaryDirectory() as root:
            now = dt.datetime.now(dt.timezone.utc)
            data = self.fixture()
            data["issue"]["labels"].append({"name": "auto-dispatch"})
            data["issue"]["labels"][1]["name"] = "status:available"
            data["issue"]["assignees"] = []
            data["pr"]["title"] = "Preserved automatic checkpoint"
            data["comments"] = data["comments"][:2]
            data["comments"][1]["body"] = "CLAIM_RELEASED reason=worker_draft_checkpoint runner=worker"
            for c in data["comments"]:
                c["created_at"] = _stamp(now - dt.timedelta(minutes=10))
            data["comments"].append(self._orphan_claim(now))
            state = pathlib.Path(root) / "state.json"
            state.write_text(json.dumps(data))
            gh = pathlib.Path(root) / "gh"
            gh.write_text('#!/usr/bin/env bash\nexec python3 "$CHECKPOINT_TEST_FILE" --gh "$@"\n')
            gh.chmod(0o700)
            env = {**os.environ, "PATH": root + os.pathsep + os.environ["PATH"], "HOME": root,
                   "CHECKPOINT_TEST_FILE": str(pathlib.Path(__file__).with_name("checkpoint_github_fixture.py")),
                   "CHECKPOINT_TEST_STATE": str(state), "AIDEVOPS_TEST_MODE": "1",
                   "AIDEVOPS_ATTEMPT_ID": "automatic-fixture", "AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS": "1",
                   "DISPATCH_CLAIM_WINDOW": "0", "AIDEVOPS_DEVICE_ID": "test-device",
                   "AIDEVOPS_DISPATCH_LEASE_SESSION": "unrelated-parent-session"}
            result = subprocess.run([self.bash, "-c", RETRY_COMMAND, "test", str(self.scripts)],  # nosec B603
                                    env=env, capture_output=True, text=True, timeout=60, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            saved = json.loads(state.read_text())
            events = []
            for c in saved["comments"]:
                if "CLAIM_RELEASED" in c["body"] and "oldnonce" in c["body"]:
                    events.append("old-release")
                elif "DISPATCH_CLAIM " in c["body"] and "oldnonce" not in c["body"]:
                    events.append("new-claim")
            self.assertEqual(events, ["old-release", "new-claim"])
            self.assertEqual(saved["issue"]["assignees"], [])
            self.assertIn({"name": "status:available"}, saved["issue"]["labels"])
