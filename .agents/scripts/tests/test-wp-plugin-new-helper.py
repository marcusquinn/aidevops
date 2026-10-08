#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise create with real scratch Git worktrees and offline service stubs."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")


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
sys.exit(subprocess.call(["/usr/bin/git", *args]))
''')
        self.write_executable(self.bin / "gh", '''#!/usr/bin/env bash
set -eu
case "$*" in
    "release view "*) printf '%s\\n' v1.0.28 ;;
    "repo view "*) exit 1 ;;
    "repo create "*) exit 0 ;;
    *"/compare/"*) printf '%s\\n' identical ;;
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
            ["/usr/bin/git", "-C", str(path), *args], env=self.env, text=True
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


if __name__ == "__main__":
    unittest.main()
