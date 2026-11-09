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
        # GraphQL fallback pages keyed by (slug, cursor); absent means failure.
        self.graphql_pages = {}

    def git(self, *arguments):
        return _git("-C", str(self.path), *arguments)

    def graphql(self, argv):
        fields = dict(argv[index + 1].split("=", 1)
                      for index in range(3, len(argv), 2) if argv[index] == "-f")
        key = (f"{fields['owner']}/{fields['name']}", fields.get("cursor"))
        response = self.graphql_pages.get(key)
        if response is None:
            raise subprocess.CalledProcessError(1, argv[:3])
        return subprocess.CompletedProcess(argv, 0, json.dumps(response))

    def graphql_page(self, nodes, fork=None, cursor=None):
        return {"data": {"repository": {
            "isFork": fork is not None,
            "parent": {"nameWithOwner": fork} if fork else None,
            "pullRequests": {"pageInfo": {"hasNextPage": cursor is not None,
                                          "endCursor": cursor},
                             "nodes": nodes}}}}

    def api(self, argv, **kwargs):
        self.assertEqual(argv[:2], ["gh", "api"])
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["timeout"], 60)
        if argv[2] == "graphql":
            return self.graphql(argv)
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
            [{"head": {"sha": "old-sha", "ref": "topic",
                       "repo": {"full_name": "Contributor/Fork"}}}],
        ]
        self.assertEqual(self.hold()[0], "open-pull-request")

    def test_other_fork_branch_does_not_hold(self):
        self.responses["repos/upstream/project/pulls?state=open&per_page=100"] = [
            [{"head": {"sha": "other-sha", "ref": "topic",
                       "repo": {"full_name": "other/fork"}}}],
        ]
        self.assertIsNone(self.hold()[0])

    def test_other_fork_exact_sha_still_holds(self):
        self.responses["repos/upstream/project/pulls?state=open&per_page=100"] = [
            [{"head": {"sha": self.head, "ref": "topic",
                       "repo": {"full_name": "other/fork"}}}],
        ]
        self.assertEqual(self.hold()[0], "open-pull-request")

    def test_missing_or_deleted_head_repository_cannot_match_branch(self):
        for repository in (None, {}, {"full_name": None}):
            with self.subTest(repository=repository):
                self.responses["repos/upstream/project/pulls?state=open&per_page=100"] = [
                    [{"head": {"sha": "old-sha", "ref": "topic", "repo": repository}}],
                ]
                self.assertIsNone(self.hold()[0])

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
            ("repos/contributor/fork", {"fork": True, "parent": {"full_name": "../bad"},
                                       "source": {"full_name": "upstream/project"}}),
            ("repos/contributor/fork", subprocess.CalledProcessError(1, ["gh", "api"])),
            ("repos/upstream/project/pulls?state=open&per_page=100", []),
            ("repos/upstream/project/pulls?state=open&per_page=100", [[{}]]),
            ("repos/upstream/project/pulls?state=open&per_page=100",
             [[{"head": {"ref": "", "sha": "other-sha"}}]]),
            ("repos/upstream/project/pulls?state=open&per_page=100",
             [[{"head": {"ref": "other-branch", "sha": ""}}]]),
            ("repos/upstream/project/pulls?state=open&per_page=100",
             [[{"head": {"ref": "", "sha": ""}}]]),
            ("repos/upstream/project/pulls?state=open&per_page=100",
             subprocess.TimeoutExpired(["gh", "api"], 60)),
        ]
        for endpoint, response in cases:
            with self.subTest(endpoint=endpoint, response=response):
                original = self.responses[endpoint]
                self.responses[endpoint] = response
                self.assertEqual(self.hold()[0], "pull-request-state-unavailable")
                self.responses[endpoint] = original

    def test_rest_deferral_uses_complete_graphql_evidence(self):
        self.responses["repos/contributor/fork"] = subprocess.CalledProcessError(75, ["gh"])
        match = {"headRefName": "other", "headRefOid": self.head, "headRepository": None}
        self.graphql_pages = {
            ("contributor/fork", None): self.graphql_page([], fork="upstream/project"),
            ("upstream/project", None): self.graphql_page([], cursor="c1"),
            ("upstream/project", "c1"): self.graphql_page([match]),
        }
        self.assertEqual(self.hold()[0], "open-pull-request")
        match["headRefOid"] = "other-sha"
        self.assertIsNone(self.hold()[0])
        match["headRefName"] = "topic"
        match["headRepository"] = {"nameWithOwner": "Contributor/Fork"}
        self.assertEqual(self.hold()[0], "open-pull-request")

    def test_incomplete_or_malformed_graphql_fallback_holds(self):
        self.responses["repos/contributor/fork"] = subprocess.TimeoutExpired(["gh"], 60)
        fork = ("contributor/fork", None)
        upstream = ("upstream/project", None)
        cases = [
            {fork: self.graphql_page([], fork="upstream/project")},
            {fork: self.graphql_page([], fork="upstream/project"),
             upstream: self.graphql_page([], cursor="")},
            {fork: self.graphql_page([{"headRefName": "", "headRefOid": "x"}])},
            {fork: {"errors": [{"message": "x"}], "data": None}},
            {fork: self.graphql_page([], fork="../bad")},
        ]
        for pages in cases:
            with self.subTest(pages=pages):
                self.graphql_pages = pages
                self.assertEqual(self.hold()[0], "pull-request-state-unavailable")

    def test_repeated_graphql_cursor_fails_after_second_page(self):
        self.responses["repos/contributor/fork"] = subprocess.CalledProcessError(75, ["gh"])
        self.graphql_pages = {
            ("contributor/fork", None): self.graphql_page([], cursor="c1"),
            ("contributor/fork", "c1"): self.graphql_page([], cursor="c1"),
        }
        with patch.object(pull_requests.subprocess, "run", side_effect=self.api) as calls:
            with self.assertRaises(subprocess.CalledProcessError):
                pull_requests.open_pull_requests("contributor/fork")
        self.assertEqual(calls.call_count, 3)  # One REST call and two GraphQL pages.

    def test_malformed_rest_evidence_does_not_fall_back(self):
        self.responses["repos/contributor/fork"] = {"fork": "yes"}
        self.graphql_pages = {("contributor/fork", None): self.graphql_page([])}
        reason, endpoints = self.hold()
        self.assertEqual(reason, "pull-request-state-unavailable")
        self.assertEqual(endpoints, ["repos/contributor/fork"])

    def test_no_remotes_does_not_query_api(self):
        self.git("remote", "remove", "origin")
        self.assertEqual(self.hold(), (None, []))
