"""Real native exec/denial checks using disposable state and owned subprocesses."""

import json
import os
from pathlib import Path
import subprocess  # nosec B404 # owned native processes in disposable test directories
import sys
import tempfile
import unittest
from uuid import uuid4

from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.registry import reconcile
from worker_lifecycle.storage import LifecycleRegistry


ENTRY = Path(__file__).resolve().parents[1] / "worker-launch.py"


class AdmittedLaunchContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.store = LifecycleRegistry.initialize(self.root / "state")
        self.generation = str(uuid4())
        self.gate = AdmissionRegistry(self.store)
        self.gate.open_generation(str(uuid4()), self.generation, self.root)
        self.marker = self.root / "executed"

    def launch(self, *, state=None, generation=None, run=None, cwd=None, worktree=None, extra=()):
        return subprocess.run(  # nosec B603 # fixed interpreter and fixture program, argv only
            [sys.executable, "-E", "-s", "-B", str(ENTRY),
             "--state-dir", str(state or self.store.directory),
             "--worktree", str(worktree or self.root),
             "--generation-id", generation or self.generation,
             "--run-id", run or str(uuid4()), *extra, "--", sys.executable, "-c",
             "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('yes'); print('native-output'); sys.exit(23)",
             str(self.marker)],
            cwd=cwd or self.root, capture_output=True, text=True, timeout=10,
        )

    def assert_denied(self, result):
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.marker.exists())

    def test_native_output_exit_and_process_reconciliation(self):
        result = self.launch()
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(result.stdout, "native-output\n")
        self.assertTrue(self.marker.exists())
        self.assertEqual(reconcile(self.store)["processed"], 1)
        self.assertEqual(self.store.summary()["runs"], {"ended": 1})

    def test_closed_generation_never_executes(self):
        self.gate.close_generation(str(uuid4()), self.generation)
        before = self.store.summary()
        self.assert_denied(self.launch())
        self.assertEqual(before, self.store.summary())

    def test_native_environment_consumes_only_admission_ids(self):
        """Consume attempt IDs without altering unrelated native environment."""
        run = str(uuid4())
        names = ("AIDEVOPS_LIFECYCLE_RUN_ID", "AIDEVOPS_LIFECYCLE_GENERATION_ID",
                 "AIDEVOPS_LIFECYCLE_STATE_DIR", "NATIVE_ENV_SENTINEL")
        environment = dict(
            os.environ,
            AIDEVOPS_LIFECYCLE_RUN_ID=run,
            AIDEVOPS_LIFECYCLE_GENERATION_ID=self.generation,
            AIDEVOPS_LIFECYCLE_STATE_DIR=str(self.store.directory),
            NATIVE_ENV_SENTINEL="preserved",
        )
        # Fixed native interpreter and fixture argv, not external command text.
        result = subprocess.run(  # noqa: S603  # nosec B603
            [sys.executable, "-E", "-s", "-B", str(ENTRY),
             "--state-dir", str(self.store.directory), "--worktree", str(self.root),
             "--generation-id", self.generation, "--run-id", run, "--",
             sys.executable, "-E", "-s", "-B", "-c",
             "import json,os,sys; "
             "print(json.dumps([os.environ.get(name) for name in sys.argv[1:]]))",
             *names],
            cwd=self.root, env=environment, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            [None, None, str(self.store.directory), "preserved"],
        )
        self.assertEqual(environment[names[0]], run)
        self.assertEqual(self.store.summary()["bindings"], 1)

    def test_missing_registry_never_executes_or_initializes(self):
        missing = self.root / "missing"
        self.assert_denied(self.launch(state=missing))
        self.assertFalse(missing.exists())

    def test_unknown_generation_never_executes(self):
        self.assert_denied(self.launch(generation=str(uuid4())))

    def test_declared_worktree_does_not_require_matching_cwd(self):
        other = self.root / "other"
        other.mkdir()
        result = self.launch(cwd=other)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertTrue(self.marker.exists())
        with self.store.connection() as connection:
            row = connection.execute("SELECT generation_id,path FROM generations").fetchone()
            self.assertEqual((row["generation_id"], row["path"]), (self.generation, str(self.root)))

    def test_wrong_generation_path_never_executes(self):
        other = self.root / "other"
        other.mkdir()
        self.assert_denied(self.launch(cwd=other, worktree=other))
        self.assertEqual(self.store.summary()["bindings"], 0)

    def test_retry_with_same_run_id_does_not_execute_twice(self):
        run = str(uuid4())
        self.assertEqual(self.launch(run=run).returncode, 23)
        self.marker.unlink()
        self.assert_denied(self.launch(run=run))
        self.assertEqual(self.store.summary()["bindings"], 1)

    def test_schema_one_requires_explicit_upgrade(self):
        with self.store.connection(write=True) as connection:
            connection.execute("DROP TABLE generation_admissions")
            connection.execute("PRAGMA user_version=1")
        self.assert_denied(self.launch())
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)

    def test_full_journal_never_executes(self):
        with self.store.connection(write=True) as connection:
            connection.execute("UPDATE metadata SET max_events=1")
        self.assert_denied(self.launch())
        self.assertEqual(self.store.summary()["bindings"], 0)

    def test_initialize_flag_cannot_enable_fail_open_fallback(self):
        result = self.launch(extra=("--initialize",))
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
