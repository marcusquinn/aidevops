"""Fork/upstream PR holds use complete API evidence, never live cleanup."""

import json
import os
from pathlib import Path
import subprocess  # nosec B404 # disposable Git fixture and mocked gh
import tempfile
import unittest
from unittest.mock import patch

from worker_lifecycle import pull_requests
from worker_lifecycle.retirement import _git


class ForkPullRequestContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fork-pr-hold-")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("GIT_")}
        environment.update(HOME=str(self.path), XDG_CONFIG_HOME=str(self.path / "config"))
        isolated = patch.dict(os.environ, environment, clear=True)
        isolated.start()
        self.addCleanup(isolated.stop)
        _git("init", "-q", "--initial-branch=topic", str(self.path))
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-q", "--allow-empty", "-m", "fixture")
        self.git("remote", "add", "origin", "https://github.com/contributor/fork.git")
        self.head = self.git("rev-parse", "HEAD")
        self.metadata = {
            "fork": True, "parent": {"full_name": "upstream/project"},
            "source": {"full_name": "upstream/project"},
        }
        self.responses = {
            "repos/contributor/fork": self.metadata,
            "repos/contributor/fork/pulls?state=open&per_page=100": [[]],
            "repos/upstream/project/pulls?state=open&per_page=100": [[]],
        }

    def git(self, *arguments):
        return _git("-C", str(self.path), *arguments)

    def api(self, argv, **kwargs):
        self.assertEqual(argv[:2], ["gh", "api"])
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["timeout"], 60)
        if "/pulls?" in argv[-1]:
            self.assertEqual(argv[2:4], ["--paginate", "--slurp"])
        response = self.responses[argv[-1]]
        if isinstance(response, Exception):
            raise response
        return subprocess.CompletedProcess(argv, 0, json.dumps(response))

    def hold(self):
        # Mock only gh; worktree identity and remote checks use real Git.
        native = subprocess.run

        def run(argv, **kwargs):
            return self.api(argv, **kwargs) if argv[0] == "gh" else native(argv, **kwargs)

        with patch.object(pull_requests.subprocess, "run", side_effect=run) as calls:
            cache = pull_requests.OpenPullRequestCache()
            reason = cache.hold_reason(self.path, "contributor/fork")
            self.assertEqual(cache.hold_reason(self.path, "contributor/fork"), reason)
        endpoints = [call.args[0][-1] for call in calls.call_args_list
                     if call.args[0][0] == "gh"]
        self.assertEqual(len(endpoints), len(set(endpoints)), "API evidence is cached")
        return reason, endpoints

    def test_upstream_sha_on_later_page_holds_detached_head(self):
        self.git("checkout", "--detach", "-q")
        self.responses["repos/upstream/project/pulls?state=open&per_page=100"] = [
            [], [{"head": {"sha": self.head, "ref": "different-name"}}],
        ]
        reason, endpoints = self.hold()
        self.assertEqual(reason, "open-pull-request")
        self.assertEqual(len(endpoints), 3)

    def test_upstream_branch_holds_when_local_head_has_advanced(self):
        self.responses["repos/upstream/project/pulls?state=open&per_page=100"] = [
            [{"head": {"sha": "old-sha", "ref": "topic"}}],
        ]
        self.assertEqual(self.hold()[0], "open-pull-request")

    def test_distinct_source_is_checked(self):
        self.metadata["source"] = {"full_name": "original/project"}
        self.responses["repos/original/project/pulls?state=open&per_page=100"] = [
            [{"head": {"sha": self.head, "ref": "topic"}}],
        ]
        reason, endpoints = self.hold()
        self.assertEqual(reason, "open-pull-request")
        self.assertEqual(len(endpoints), 4)

    def test_empty_complete_evidence_does_not_hold(self):
        self.assertIsNone(self.hold()[0])

    def test_nonfork_uses_only_configured_repository(self):
        self.responses["repos/contributor/fork"] = {"fork": False}
        reason, endpoints = self.hold()
        self.assertIsNone(reason)
        self.assertEqual(len(endpoints), 2)

    def test_api_failure_or_malformed_evidence_holds(self):
        cases = [
            ("repos/contributor/fork", {}),
            ("repos/contributor/fork", {"fork": True}),
            ("repos/contributor/fork", {"fork": True, "parent": {"full_name": "../bad"}}),
            ("repos/contributor/fork", subprocess.CalledProcessError(1, ["gh", "api"])),
            ("repos/upstream/project/pulls?state=open&per_page=100", []),
            ("repos/upstream/project/pulls?state=open&per_page=100", [[{}]]),
            ("repos/upstream/project/pulls?state=open&per_page=100",
             subprocess.TimeoutExpired(["gh", "api"], 60)),
        ]
        for endpoint, response in cases:
            with self.subTest(endpoint=endpoint, response=response):
                original = self.responses[endpoint]
                self.responses[endpoint] = response
                self.assertEqual(self.hold()[0], "pull-request-state-unavailable")
                self.responses[endpoint] = original

    def test_no_remotes_does_not_query_api(self):
        self.git("remote", "remove", "origin")
        self.assertEqual(self.hold(), (None, []))
