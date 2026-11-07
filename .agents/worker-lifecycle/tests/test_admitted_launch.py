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

    def launch(self, *, state=None, generation=None, run=None, cwd=None, worktree=None, extra=(),
               env=None):
        return subprocess.run(  # nosec B603 # fixed interpreter and fixture program, argv only
            [sys.executable, "-E", "-s", "-B", str(ENTRY),
             "--state-dir", str(state or self.store.directory),
             "--worktree", str(worktree or self.root),
             "--generation-id", generation or self.generation,
             "--run-id", run or str(uuid4()), *extra, "--", sys.executable, "-c",
             "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
             "p.write_text(p.read_text()+'yes' if p.exists() else 'yes'); "
             "print('native-output'); sys.exit(23)",
             str(self.marker)],
            cwd=cwd or self.root, capture_output=True, text=True, timeout=10,
            env=None if env is None else dict(os.environ, **env),
        )

    def hold_writer(self, seconds, *, close=False):
        """A separate process holds the registry writer, optionally closing the gate."""
        program = (
            "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1], isolation_level=None); "
            "c.execute('BEGIN IMMEDIATE'); print('held', flush=True); time.sleep(float(sys.argv[2])); "
            "sys.argv[3] and c.execute(\"UPDATE generation_admissions SET state='closed' "
            "WHERE generation_id=?\", (sys.argv[3],)); c.commit()"
        )
        holder = subprocess.Popen(  # nosec B603 # fixed interpreter and fixture program
            [sys.executable, "-E", "-s", "-B", "-c", program, str(self.store.path),
             str(seconds), self.generation if close else ""],
            stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.stdout.close)
        self.addCleanup(holder.wait, 30)
        self.assertEqual(holder.stdout.readline(), "held\n")
        return holder

    def test_transient_writer_contention_recovers_and_executes_once(self):
        """GH#36921: a writer held past the busy timeout delays, not denies, admission."""
        self.hold_writer(3)
        result = self.launch(env={"AIDEVOPS_LIFECYCLE_ADMISSION_WAIT_SECONDS": "30"})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.marker.read_text(), "yes")
        self.assertIn("admission-retry reason=OperationalError code=database-locked "
                      "category=contention attempt=1", result.stderr)
        self.assertEqual(self.store.summary()["bindings"], 1)

    def test_persistent_writer_contention_fails_closed(self):
        """Contention outlasting the bounded wait denies with a sanitized reason."""
        self.hold_writer(4)
        result = self.launch(env={"AIDEVOPS_LIFECYCLE_ADMISSION_WAIT_SECONDS": "1"})
        self.assert_denied(result)
        self.assertIn("admission-denied reason=OperationalError code=database-locked "
                      "category=contention", result.stderr)
        self.assertNotIn(str(self.root), result.stderr)

    def test_generation_closed_while_waiting_never_executes(self):
        """A close committed by the contending writer wins over the waiting admission."""
        self.hold_writer(3, close=True)
        self.assert_denied(self.launch(env={"AIDEVOPS_LIFECYCLE_ADMISSION_WAIT_SECONDS": "30"}))
        self.assertEqual(self.store.summary()["bindings"], 0)

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
