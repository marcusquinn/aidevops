"""Repository integration of bare/sandbox launch boundaries with native commands.

No AI runtime, network request or production database is used. These Bash-dependent
tests are intentionally outside the portable standard-library validator.
"""

import json
import os
from pathlib import Path
import subprocess  # nosec B404 # fixed launcher fixtures, not external commands
import sys
import tempfile
import unittest
from uuid import uuid4

from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.registry import reconcile
from worker_lifecycle.storage import LifecycleRegistry


SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
BARE = r'''
SCRIPT_DIR="$1"
source "$SCRIPT_DIR/headless-runtime-invoke.sh"
private_workload=0; runtime_role=worker; public_triage=0; egress_mode=off
_invoke_work_dir="$3"; output_file="$2/output"; exit_code_file="$2/exit"
HEADLESS_SANDBOX_TIMEOUT_DEFAULT=10
_headless_private_workload_enabled() { return 1; }
_headless_opencode_sandbox_required() { return 1; }
run_without_opencode_session_env() { "$@"; }
print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
_oc_cmd=(touch "$2/executed")
if _invoke_opencode_validate_context; then
    _invoke_opencode_set_working_directory || exit "$?"
    _invoke_opencode_run_bare || exit "$?"
fi
status=0
IFS= read -r status <"$exit_code_file" || true
exit "$status"
'''

CLAUDE = r'''
SCRIPT_DIR="$1"
source "$SCRIPT_DIR/headless-runtime-worker-invocation.sh"
SANDBOX_EXEC_HELPER="$SCRIPT_DIR/sandbox-exec-helper.sh"
HEADLESS_SANDBOX_TIMEOUT_DEFAULT=10
AIDEVOPS_WORKER_EGRESS_MODE=off
if [[ "$3" == claude-bare ]]; then AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1; fi
_headless_private_workload_enabled() { return 1; }
prepare_headless_signing_sandbox_env() { return 0; }
prepare_headless_git_auth_sandbox_env() { return 0; }
build_sandbox_passthrough_csv() { return 0; }
print_info() { return 0; }
print_error() { return 0; }
_invoke_claude "$2/output" "$2/exit" "$4" touch "$2/executed"
status=0
IFS= read -r status <"$2/exit" || true
exit "$status"
'''

PATHS = ("bare", "sandbox", "claude-bare", "claude-sandbox")


class LauncherPathsContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="launcher-paths-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.store = LifecycleRegistry.initialize(self.root / "state")
        self.gate = AdmissionRegistry(self.store)
        self.generation = str(uuid4())
        self.gate.open_generation(str(uuid4()), self.generation, self.root)
        self.marker = self.root / "executed"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("AIDEVOPS_")}
        self.env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / "config"),
                        AIDEVOPS_LIFECYCLE_STATE_DIR=str(self.store.directory),
                        AIDEVOPS_LIFECYCLE_WORKTREE=str(self.root),
                        AIDEVOPS_LIFECYCLE_GENERATION_ID=self.generation)

    def launch(self, kind, *, missing_context=False, **overrides):
        env = dict(self.env, AIDEVOPS_LIFECYCLE_RUN_ID=str(uuid4()), **overrides)
        directory = "" if missing_context else str(self.root)
        if missing_context:
            for name in (
                "AIDEVOPS_LIFECYCLE_RUN_ID", "AIDEVOPS_LIFECYCLE_GENERATION_ID",
                "AIDEVOPS_LIFECYCLE_WORKTREE",
            ):
                env.pop(name, None)
        if kind == "bare":
            command = ["bash", "-c", BARE, "fixture", str(SCRIPTS),
                       str(self.root), directory]
        elif kind.startswith("claude-"):
            command = ["bash", "-c", CLAUDE, "fixture", str(SCRIPTS),
                       str(self.root), kind, directory]
        else:
            command = ["bash", str(SCRIPTS / "sandbox-exec-helper.sh"),
                       "run", "touch", str(self.marker)]
        return subprocess.run(  # nosec B603 # constant fixture argv
            command, cwd=self.root, env=env, capture_output=True,
            text=True, timeout=30,
        )

    def test_launcher_paths_admit_native_command(self):
        for kind in PATHS:
            with self.subTest(kind=kind):
                result = self.launch(kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(self.marker.exists())
                self.marker.unlink()
        self.assertEqual(self.store.summary()["bindings"], len(PATHS))
        reconcile(self.store)
        self.assertEqual(self.store.summary()["runs"], {"ended": len(PATHS)})

    def test_launcher_paths_refuse_closed_generation(self):
        self.gate.close_generation(str(uuid4()), self.generation)
        before = self.store.summary()
        for kind in PATHS:
            with self.subTest(kind=kind):
                result = self.launch(kind)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertFalse(self.marker.exists())
        self.assertEqual(before, self.store.summary())

    def test_worker_entry_points_require_directory_not_inherited_cwd(self):
        self.gate.close_generation(str(uuid4()), self.generation)
        before = self.store.summary()
        for kind in ("bare", "claude-bare", "claude-sandbox"):
            with self.subTest(kind=kind):
                result = self.launch(kind, missing_context=True)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertFalse(self.marker.exists())
        self.assertEqual(self.store.summary(), before)

    def test_observation_opt_out_cannot_bypass_required_admission(self):
        for kind in PATHS:
            with self.subTest(kind=kind):
                result = self.launch(kind, AIDEVOPS_LIFECYCLE_DISABLED="1")
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertFalse(self.marker.exists())

    def test_partial_context_cannot_fall_back_to_observation(self):
        self.env["AIDEVOPS_LIFECYCLE_GENERATION_ID"] = ""
        for kind in PATHS:
            with self.subTest(kind=kind):
                result = self.launch(kind)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertFalse(self.marker.exists())

    def test_private_sandbox_does_not_leak_into_public_admission_store(self):
        before = self.store.summary()
        result = self.launch("sandbox", AIDEVOPS_PRIVATE_WORKLOAD="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(self.marker.exists())
        self.assertEqual(before, self.store.summary())

    def test_cleanup_entrypoints_use_registry_without_legacy_fallback(self):
        repo, target = self.root / "repository", self.root / "candidate"
        output = self.root / "archives"
        env = {key: value for key, value in self.env.items()
               if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                   GIT_TERMINAL_PROMPT="0", AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(output))

        def invoke(command, cwd=None):
            return subprocess.run(  # nosec B603 # fixed fixture argv, private state
                command, env=env, cwd=cwd or Path(__file__).resolve().parents[1],
                capture_output=True, text=True, check=True, timeout=120,
            )

        invoke(["git", "init", "-q", "--initial-branch=main", str(repo)])
        invoke(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c",
                "user.email=fixture@example.invalid", "commit", "-q",
                "--allow-empty", "-m", "fixture"])
        program = (
            "import os,sys; from pathlib import Path; "
            "from worker_lifecycle.creation import WorktreeSpec, create_worktree; "
            "from worker_lifecycle.storage import LifecycleRegistry; "
            "target=Path(sys.argv[3]); "
            "create_worktree(LifecycleRegistry(Path(sys.argv[1])), "
            "WorktreeSpec(Path(sys.argv[2]),target,'HEAD',('--detach',)),"
            "os.getpid(),'fixture'); "
            "(target/'payload').write_text('preserve')"
        )
        creator = [sys.executable, "-E", "-s", "-B", "-c", program,
                   str(self.store.directory), str(repo), str(target)]
        invoke(creator)
        shell = r'''
legacy_marker="$2/legacy-called"
gh() { touch "$legacy_marker"; return 1; }
source "$1/pulse-cleanup-worktree-removal.sh"
LOGFILE="$2/pulse.log"
_pc_cleanup_resumable() { touch "$legacy_marker"; return 1; }
_pc_cleanup_fixture_passes() { touch "$legacy_marker"; return 1; }
cleanup_worktrees 120
printf '%s %s %s\n' "$CLEANUP_WORKTREES_REMOVED_COUNT" \
    "$CLEANUP_WORKTREES_ARCHIVED_COUNT" "$CLEANUP_WORKTREES_SKIPPED"
'''
        command = ["bash", "-c", shell, "fixture", str(SCRIPTS), str(self.root)]
        self.assertEqual(invoke(command).stdout.strip(), "0 0 1")
        self.assertTrue((target / "payload").exists())
        config = self.root / ".config" / "aidevops" / "repos.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"initialized_repos": [{
            "path": str(repo), "slug": "fixture/repository",
        }]}))
        self.assertEqual(invoke(command).stdout.strip(), "1 1 0")
        self.assertFalse(target.exists())
        self.assertEqual(len(list(output.rglob("manifest.json"))), 1)
        self.assertFalse((self.root / "legacy-called").exists())

        compatibility = r'''
source "$1/audit-worktree-removal-helper.sh"
worktree_managed_require_removal_proof() { return 0; }
_worktree_remove_with_native_git "$2" fixture ignored true
'''
        routes = [
            ["bash", "-c", compatibility, "fixture", str(SCRIPTS), str(target)],
            ["bash", str(SCRIPTS / "worktree-helper.sh"),
             "remove", str(target), "--force"],
        ]
        for command in routes:
            with self.subTest(entrypoint=command[1]):
                invoke(creator)
                env["AIDEVOPS_LIFECYCLE_STATE_DIR"] = str(self.root / "missing-state")
                with self.assertRaises(subprocess.CalledProcessError):
                    invoke(command, cwd=repo)
                self.assertTrue((target / "payload").exists())
                env["AIDEVOPS_LIFECYCLE_STATE_DIR"] = str(self.store.directory)
                completed = invoke(command, cwd=repo)
                self.assertEqual(json.loads(completed.stdout)["status"], "retired")
                self.assertFalse(target.exists())
        self.assertEqual(len(list(output.rglob("manifest.json"))), 3)


if __name__ == "__main__":
    unittest.main()
