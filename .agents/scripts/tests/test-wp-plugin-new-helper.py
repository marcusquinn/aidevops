#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise create with real scratch Git worktrees and offline service stubs."""

import json
import os
from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
GIT = os.environ.get("AIDEVOPS_TEST_GIT_BIN") or shutil.which("git")


class PluginCreateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wp-plugin-new-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.scripts = self.root / "helpers"
        self.scripts.mkdir()
        for name in ("wp-plugin-new-helper.sh", "wp_plugin_quality.py"):
            shutil.copy2(SCRIPTS / name, self.scripts / name)
        # Keep the helper's real sibling dependencies without copying the repo.
        for dependency in SCRIPTS.iterdir():
            if dependency.name not in ("wp-plugin-new-helper.sh", "wp_plugin_quality.py",
                                       "gh-write-helper.sh"):
                (self.scripts / dependency.name).symlink_to(dependency)
        self.env = dict(os.environ, HOME=str(self.root),
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        FIXTURE_GIT=GIT,
                        WORKTREE_REGISTRY_DIR=str(self.root / "registry"),
                        WORKTREE_REGISTRY_DB=str(self.root / "registry/owners.db"),
                        AIDEVOPS_WORKTREE_BASE_DIR=str(self.root / "worktrees"),
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                        FIXTURE_ROOT=str(self.root), INIT_MODE="staged")
        self.seed = self.root / "starter"
        self.seed.mkdir()
        (self.seed / "scripts").mkdir()
        (self.seed / "README.md").write_text("# Starter\n")
        (self.seed / ".aidevops.json").write_text("{}\n")
        self.write_executable(self.seed / "scripts/rename-plugin.sh", '''#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == --help ]]; then
    printf '%s\\n' '--author-uri'
    exit 0
fi
[[ -z "$(git status --porcelain)" ]] || exit 42
printf '%s\\n' '# Renamed plugin' > README.md
''')
        self.git(self.seed, "init", "-b", "main")
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-m", "chore: starter")
        self.git(self.seed, "tag", "v1.0.28")
        self.write_executable(self.bin / "git", '''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if "ls-remote" in args:
    print("abc123\\tHEAD")
    sys.exit(0)
if "push" in args:
    sys.exit(0)
if "clone" in args:
    args[-2] = os.path.join(os.environ["FIXTURE_ROOT"], "starter")
if "commit" in args and os.environ["INIT_MODE"] == "commit-fails":
    if "chore: initialize aidevops code-quality" in args:
        sys.exit(43)
sys.exit(subprocess.call([os.environ["FIXTURE_GIT"], *args]))
''')
        self.write_executable(self.bin / "gh", '''#!/usr/bin/env bash
set -eu
case "$*" in
    "release view "*) printf '%s\\n' v1.0.28 ;;
    "repo view "*) exit 1 ;;
    "repo create "*) exit 0 ;;
    *"/compare/"*) printf '%s\\n' identical ;;
    "api repos/fixture/example-plugin")
        if [[ "${RUNNER_DENIED:-0}" == 1 ]]; then
            printf '%s\\n' '{"private":true,"owner":{"type":"Organization"}}'
        else
            printf '%s\\n' '{"private":true,"owner":{"type":"User"}}'
        fi ;;
    "api --paginate orgs/"*) printf '%s\\n' 'HTTP 403 forbidden' >&2; exit 1 ;;
    "api repos/"*) printf 'true\\tmain\\n' ;;
    *) exit 44 ;;
esac
''')
        self.write_executable(self.bin / "aidevops", '''#!/usr/bin/env bash
set -eu
if [[ "$*" == 'repos add' ]]; then exit 0; fi
[[ "$*" == 'init code-quality' ]] || exit 45
[[ "$(git rev-parse --absolute-git-dir)" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]] || exit 46
if [[ "$INIT_MODE" == clean ]]; then exit 0; fi
printf '%s\\n' quality > generated-quality.txt
printf '%s\\n' .aidevops.json > .gitignore
git add generated-quality.txt
git rm --cached .aidevops.json
if [[ "$INIT_MODE" == committed ]]; then git add -A; git commit -m 'chore: init stub'; fi
if [[ "$INIT_MODE" == init-fails ]]; then exit 47; fi
''')
        self.write_executable(self.bin / "composer", "#!/usr/bin/env bash\nexit 0\n")
        self.write_executable(self.scripts / "gh-write-helper.sh", '''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$@" > "$FIXTURE_ROOT/published-args"
cat > "$FIXTURE_ROOT/published-body"
''')

    @staticmethod
    def write_executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def git(self, path, *args):
        # Fixed Git executable and exclusively fixture-owned argv; no shell.
        return subprocess.check_output(  # nosec B603
            [GIT, "-C", str(path), *args], env=self.env, text=True
        ).strip()

    def create(self, *options):
        self.assertIsNotNone(BASH, "bash is required for the helper tests")
        # Resolved Bash executable, repository helper and fixture-only argv.
        return subprocess.run([  # nosec B603
            BASH, str(self.scripts / "wp-plugin-new-helper.sh"), "create",
            "--name", "Example Plugin", "--slug", "example-plugin",
            "--description", "Fixture plugin", "--owner", "fixture",
            "--author", "Fixture", "--author-uri", "https://example.invalid",
            "--contributors", "fixture", "--dest", str(self.root / "clone"),
            *options,
        ], env=self.env, capture_output=True, text=True)

    @property
    def worktree(self):
        return self.root / "worktrees/fixture-example-plugin-identity"

    def test_staged_init_reaches_publish_with_conventional_subjects(self):
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.worktree, "status", "--porcelain"), "")
        subjects = self.git(self.worktree, "log", "-2", "--format=%s").splitlines()
        self.assertEqual(subjects, ["chore: Example Plugin names and maker details",
                                    "chore: initialize aidevops code-quality"])
        self.assertIn("chore: Example Plugin names and maker details",
                      (self.root / "published-args").read_text())
        self.assertEqual(self.git(self.root / "clone", "log", "-1", "--format=%s"),
                         "chore: starter")
        self.assertEqual(self.git(self.root / "clone", "status", "--porcelain"), "")
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as db:
            self.assertEqual(db.execute("SELECT branch FROM worktree_owners WHERE worktree_path=?",
                                        (str(self.worktree),)).fetchone(),
                             ("chore/example-plugin-identity",))

    def test_clean_init_needs_no_empty_commit(self):
        self.env["INIT_MODE"] = "clean"
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("chore: initialize aidevops code-quality",
                         self.git(self.worktree, "log", "--format=%s"))

    def test_already_committed_init(self):
        self.env["INIT_MODE"] = "committed"
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("chore: init stub", self.git(self.worktree, "log", "--format=%s"))

    def test_failed_init_or_commit_preserves_changes_without_publish(self):
        self.env["INIT_MODE"] = "commit-fails"
        result = self.create()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "published-args").exists())
        self.assertIn("generated-quality.txt", self.git(self.worktree, "status", "--porcelain"))
        self.assertEqual((self.worktree / "README.md").read_text(), "# Starter\n")

    def test_failed_init(self):
        self.env["INIT_MODE"] = "init-fails"
        result = self.create()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "published-args").exists())
        self.assertTrue((self.worktree / "generated-quality.txt").exists())

    def test_runner_permission_failure_stops_before_clone_or_publish(self):
        self.env["RUNNER_DENIED"] = "1"
        result = self.create()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repo-ensure --repo fixture/example-plugin", result.stdout)
        self.assertFalse((self.root / "published-args").exists())
        self.assertFalse((self.root / "clone").exists())

    def test_local_only_create_is_clean_and_does_not_publish(self):
        result = self.create("--no-github")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.worktree, "status", "--porcelain"), "")
        self.assertEqual(self.git(self.worktree, "log", "-1", "--format=%s"),
                         "chore: Example Plugin names and maker details")
        self.assertFalse((self.root / "published-args").exists())

    def test_local_only_dry_run_prints_plan_without_creating_paths(self):
        result = self.create("--no-github", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GitHub:       none (--no-github)", result.stdout)
        self.assertIn("Dry run: nothing changed", result.stdout + result.stderr)
        self.assertFalse((self.root / "clone").exists())
        self.assertFalse(self.worktree.exists())


class RunnerEnrollmentTest(unittest.TestCase):
    """Exercise the production CLI with offline GitHub responses and real jq."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plugin-runners-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state.json"
        self.log = self.root / "calls.jsonl"
        self.data = {
            "metadata": {"id": 42, "private": True, "owner": {"type": "Organization"}},
            "groups": [{"id": 7, "name": "Private pool", "visibility": "selected",
                        "allows_public_repositories": False}],
            "runners": [{"labels": [{"name": "linux", "type": "read-only"},
                                     {"name": "pool", "type": "custom"}]}],
            "fork": {"run_workflows_from_fork_pull_requests": False},
            "members": [10, 11], "variable": "", "fail": "",
        }
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                        RUNNER_STATE=str(self.state), RUNNER_LOG=str(self.log))
        PluginCreateTest.write_executable(self.root / "gh", '''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
state = Path(os.environ["RUNNER_STATE"])
d = json.loads(state.read_text())
with open(os.environ["RUNNER_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["variable", "set"]:
    if d["fail"] == "variable": sys.exit(1)
    d["variable"] = args[args.index("--body") + 1]
    state.write_text(json.dumps(d))
    sys.exit(0)
assert args[0] == "api", args
endpoint = next(a for a in args if a.startswith(("repos/", "orgs/"))).split("?")[0]
if endpoint == "repos/fixture/plugin": out = d["metadata"]
elif endpoint.endswith("/runner-groups"):
    if d["fail"] == "groups":
        print("HTTP 403 forbidden", file=sys.stderr)
        sys.exit(1)
    out = {"runner_groups": d["groups"]}
elif endpoint.endswith("/runners"): out = {"runners": d["runners"]}
elif endpoint.endswith("/fork-pr-workflows-private-repos"): out = d["fork"]
elif endpoint.endswith("/repositories/42"):
    assert "PUT" in args, args
    if d["fail"] == "membership":
        print("HTTP 403 forbidden", file=sys.stderr)
        sys.exit(1)
    if 42 not in d["members"]: d["members"].append(42)
    state.write_text(json.dumps(d))
    sys.exit(0)
elif endpoint.endswith("/repositories"):
    out = {"repositories": [{"id": i} for i in d["members"]]}
elif endpoint.endswith("/variables/CI_RUNNER"): out = {"value": d["variable"]}
else: raise AssertionError(args)
if "--jq" in args:
    sys.exit(subprocess.run(["jq", "-r", args[args.index("--jq") + 1]],
                            input=json.dumps(out), text=True).returncode)
print(json.dumps(out))
''')

    def enroll(self, *options, reset=True):
        if reset:
            self.state.write_text(json.dumps(self.data))
        return subprocess.run(  # nosec B603 - fixed local helper and fixture argv
            [BASH, str(SCRIPTS / "github-runner-org-helper.sh"), "repo-ensure",
             "--repo", "fixture/plugin", *options],
            env=self.env, capture_output=True, text=True)

    def writes(self):
        return [call for call in map(json.loads, self.log.read_text().splitlines())
                if "PUT" in call or call[:2] == ["variable", "set"]]

    def test_additive_enrollment_and_retry(self):
        for reset in (True, False):
            result = self.enroll(reset=reset)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            state = json.loads(self.state.read_text())
            self.assertEqual(state["members"], [10, 11, 42])
            self.assertEqual(state["variable"], "pool")
        self.assertIn("enrollment verified", result.stdout)
        self.assertTrue(all("PATCH" not in call for call in self.writes()))

    def test_dry_run_is_read_only_and_prints_exact_commands(self):
        result = self.enroll("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(), [])
        self.assertIn("gh api -X PUT orgs/fixture/actions/runner-groups/7/repositories/42", result.stdout)
        self.assertIn("gh variable set CI_RUNNER --repo fixture/plugin --body pool", result.stdout)

    def test_fork_enabled_or_unknown_never_writes(self):
        for fork in ({"run_workflows_from_fork_pull_requests": True}, {}):
            self.data["fork"] = fork
            result = self.enroll()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.writes(), [])

    def test_public_and_personal_repos_skip(self):
        for private, owner in ((False, "Organization"), (True, "User")):
            self.data["metadata"].update(private=private, owner={"type": owner})
            result = self.enroll()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("skipped", result.stdout)
            self.assertEqual(self.writes(), [])

    def test_no_selected_group_keeps_hosted_fallback(self):
        for groups in ([], [{"id": 1, "visibility": "all"}]):
            self.data["groups"] = groups
            result = self.enroll()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("fallback", result.stdout)
            self.assertEqual(self.writes(), [])

    def test_multiple_groups_require_explicit_selection(self):
        self.data["groups"].append(dict(self.data["groups"][0], id=8, name="Other"))
        result = self.enroll()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.writes(), [])
        result = self.enroll("--group", "Private pool")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unsafe_group_policies_refused(self):
        for field in ("allows_public_repositories", "inherited", "restricted_to_workflows"):
            self.data["groups"][0][field] = True
            result = self.enroll("--group", "Private pool")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.writes(), [])
            self.data["groups"][0][field] = False

    def test_empty_or_ambiguous_labels_refused(self):
        self.data["runners"][0]["labels"].append({"name": "second", "type": "custom"})
        result = self.enroll()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.writes(), [])
        result = self.enroll("--label", "pool")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unregistered_pool_refused_even_with_label(self):
        self.data["runners"] = []
        result = self.enroll("--label", "pool")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_permission_failure_prints_safe_admin_retry(self):
        self.data["fail"] = "groups"
        result = self.enroll()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repo-ensure --repo fixture/plugin", result.stdout)
        self.assertIn("admin:org", result.stderr)
        self.assertEqual(self.writes(), [])

    def test_failed_membership_does_not_set_variable(self):
        self.data["fail"] = "membership"
        result = self.enroll()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text())["variable"], "")
        self.assertIn("gh api -X PUT", result.stdout)

    def test_failed_variable_can_be_retried_without_losing_members(self):
        self.data["fail"] = "variable"
        result = self.enroll()
        self.assertNotEqual(result.returncode, 0)
        state = json.loads(self.state.read_text())
        self.assertEqual(state["members"], [10, 11, 42])
        state["fail"] = ""
        self.state.write_text(json.dumps(state))
        result = self.enroll(reset=False)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
