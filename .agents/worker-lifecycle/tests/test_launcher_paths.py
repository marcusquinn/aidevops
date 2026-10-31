"""Repository integration of bare/sandbox launch boundaries with native commands.

No AI runtime, network request or production database is used. These Bash-dependent
tests are intentionally outside the portable standard-library validator.
"""

import os
from pathlib import Path
import subprocess  # nosec B404 # fixed launcher fixtures, not external commands
import tempfile
import unittest
from uuid import uuid4

from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.storage import LifecycleRegistry


SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
BARE = r'''
SCRIPT_DIR="$1"
source "$SCRIPT_DIR/headless-runtime-invoke.sh"
private_workload=0; runtime_role=worker; public_triage=0; egress_mode=off
_invoke_work_dir="$2"; output_file="$2/output"; exit_code_file="$2/exit"
HEADLESS_SANDBOX_TIMEOUT_DEFAULT=10
_headless_opencode_sandbox_required() { return 1; }
run_without_opencode_session_env() { "$@"; }
print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
_oc_cmd=(touch "$2/executed")
_invoke_opencode_set_working_directory || exit "$?"
_invoke_opencode_run_bare || exit "$?"
status=0
IFS= read -r status <"$exit_code_file" || true
exit "$status"
'''


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
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("AIDEVOPS_")}
        self.env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / "config"),
                        AIDEVOPS_LIFECYCLE_STATE_DIR=str(self.store.directory),
                        AIDEVOPS_LIFECYCLE_WORKTREE=str(self.root),
                        AIDEVOPS_LIFECYCLE_GENERATION_ID=self.generation)

    def launch(self, kind, **overrides):
        env = dict(self.env, AIDEVOPS_LIFECYCLE_RUN_ID=str(uuid4()), **overrides)
        if kind == "bare":
            command = ["bash", "-c", BARE, "fixture", str(SCRIPTS), str(self.root)]
        else:
            command = ["bash", str(SCRIPTS / "sandbox-exec-helper.sh"), "run", "touch", str(self.marker)]
        return subprocess.run(command, cwd=self.root, env=env, capture_output=True, text=True, timeout=30)  # nosec B603 # constant fixture program, positional argv only

    def test_both_paths_admit_native_command(self):
        for kind in ("bare", "sandbox"):
            with self.subTest(kind=kind):
                result = self.launch(kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(self.marker.exists())
                self.marker.unlink()
        self.assertEqual(self.store.summary()["bindings"], 2)

    def test_both_paths_refuse_closed_generation(self):
        self.gate.close_generation(str(uuid4()), self.generation)
        before = self.store.summary()
        for kind in ("bare", "sandbox"):
            with self.subTest(kind=kind):
                result = self.launch(kind)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertFalse(self.marker.exists())
        self.assertEqual(before, self.store.summary())

    def test_observation_opt_out_cannot_bypass_required_admission(self):
        for kind in ("bare", "sandbox"):
            with self.subTest(kind=kind):
                result = self.launch(kind, AIDEVOPS_LIFECYCLE_DISABLED="1")
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertFalse(self.marker.exists())

    def test_partial_context_cannot_fall_back_to_observation(self):
        self.env["AIDEVOPS_LIFECYCLE_GENERATION_ID"] = ""
        for kind in ("bare", "sandbox"):
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


if __name__ == "__main__":
    unittest.main()
