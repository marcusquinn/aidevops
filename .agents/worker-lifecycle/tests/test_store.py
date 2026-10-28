"""Registry transaction contracts using private, disposable native SQLite stores."""

from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import json
import os
from pathlib import Path
import subprocess  # nosec B404 # bounded owned crash probes only
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle.process import ObservationUnavailable, ProcessObservation
from worker_lifecycle.runtime import adapter_for
from worker_lifecycle.registry import reconcile
from worker_lifecycle.store import LifecycleRegistry, StoreConflict


def key():
    return str(uuid4())


class StoreContract(unittest.TestCase):
    def setUp(self):
        # tempfile uses TMPDIR when supplied by the project runner.
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve() / "state"
        self.store = LifecycleRegistry.initialize(self.path)
        self.identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        self.run = key()

    def register(self):
        self.store.register(key(), self.run, self.identity)

    def test_init_never_replaces_existing_directory(self):
        with self.assertRaises(FileExistsError):
            LifecycleRegistry.initialize(self.path)
        self.assertEqual(self.store.installation_id(), self.identity.installation_id)

    def test_duplicate_event_and_payload_conflict(self):
        event = key()
        self.store.register(event, self.run, self.identity)
        self.store.register(event, self.run, self.identity)
        with self.assertRaises(StoreConflict):
            self.store.register(event, key(), self.identity)
        self.assertEqual(self.store.summary()["events"], 1)

    def test_foreign_identity_rolls_back(self):
        with self.assertRaises(StoreConflict):
            self.store.register(key(), self.run, replace(self.identity, installation_id=key()))
        self.assertEqual(self.store.summary()["events"], 0)

    def test_one_session_multiple_generations(self):
        self.register()
        self.store.bind(key(), self.run, key(), "/hypothetical/worktree-a")
        self.store.bind(key(), self.run, key(), "/hypothetical/worktree-b")
        self.assertEqual(self.store.summary()["bindings"], 2)
        self.assertFalse(self.store.summary()["cleanup_authorized"])

    def test_conflicting_claims_are_reported_not_enforced(self):
        self.register()
        another = key()
        self.store.register(key(), another, self.identity)
        generation = key()
        self.store.bind(key(), self.run, generation, "/hypothetical/worktree")
        self.store.bind(key(), another, generation, "/hypothetical/worktree")
        self.assertEqual(self.store.summary()["conflicting_generations"], 1)

    def test_terminal_observation_replay_and_no_resurrection(self):
        self.register()
        event = key()
        result = ProcessObservation("ended", "pid-absent")
        self.store.observe(event, self.run, 1, result)
        self.store.observe(event, self.run, 1, result)
        with self.assertRaises(StoreConflict):
            self.store.observe(key(), self.run, 1, ProcessObservation("alive", "identity-matched"))
        self.assertEqual(self.store.pending(), [])
        self.assertEqual(self.store.summary()["events"], 2)

    def test_stale_sample_after_binding_rolls_back_event(self):
        self.register()
        sampled = self.store.pending()[0]
        self.store.bind(key(), self.run, key(), "/hypothetical/worktree")
        second_reader = LifecycleRegistry(self.path)
        with self.assertRaises(StoreConflict):
            second_reader.observe(key(), self.run, sampled["version"], ProcessObservation("ended", "pid-absent"))
        self.assertEqual(self.store.summary()["events"], 2)
        self.assertEqual(self.store.summary()["runs"], {"bound": 1})

    def test_unknown_does_not_end_run_and_rotates_batch(self):
        self.register()
        self.store.observe(key(), self.run, 1, ProcessObservation("unknown", "permission-denied"))
        another = key()
        self.store.register(key(), another, self.identity)
        self.assertEqual(self.store.pending(1)[0]["run_id"], another)
        self.assertEqual(self.store.summary()["runs"], {"bound": 2})

    def test_readiness_failure_performs_no_writes(self):
        self.register()
        before = self.store.summary()
        with patch("worker_lifecycle.registry.require_ready", side_effect=ObservationUnavailable("denied")):
            with self.assertRaises(ObservationUnavailable):
                reconcile(self.store)
        self.assertEqual(self.store.summary(), before)

    def test_real_reconciliation_and_reopen(self):
        self.register()
        self.assertEqual(reconcile(self.store)["processed"], 1)
        reopened = LifecycleRegistry(self.path)
        self.assertEqual(reopened.summary()["runs"], {"bound": 1})
        self.assertEqual(reopened.summary()["events"], 2)

    def test_writer_exception_rolls_back(self):
        with self.assertRaises(RuntimeError):
            with self.store.connection(write=True) as connection:
                connection.execute("INSERT INTO events(event_id,payload) VALUES (?,?)", (key(), "{}"))
                raise RuntimeError("injected-before-commit")
        self.assertEqual(self.store.summary()["events"], 0)

    def test_same_process_is_sampled_once_for_multiple_sessions(self):
        self.register()
        self.store.register(key(), key(), self.identity)
        real = adapter_for(self.identity.installation_id)
        with patch("worker_lifecycle.registry.require_ready"), \
                patch("worker_lifecycle.registry.adapter_for", return_value=real), \
                patch.object(real, "observe", wraps=real.observe) as observe:
            self.assertEqual(reconcile(self.store)["processed"], 2)
            observe.assert_called_once()

    def test_concurrent_duplicate_writers_commit_one_event(self):
        event = key()
        barrier = threading.Barrier(2)

        def submit():
            store = LifecycleRegistry(self.path)
            barrier.wait(timeout=5)
            store.register(event, self.run, self.identity)

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(submit) for _ in range(2)]
            for future in futures:
                future.result(timeout=10)
        self.assertEqual(self.store.summary()["events"], 1)
        self.assertEqual(self.store.summary()["runs"], {"bound": 1})

    def test_process_crash_before_commit_rolls_back(self):
        code = ("import os,sys; from pathlib import Path; "
                "from worker_lifecycle.store import LifecycleRegistry; "
                "s=LifecycleRegistry(Path(sys.argv[1])); "
                "c=s._connect(); c.execute('BEGIN IMMEDIATE'); "
                "c.execute(\"INSERT INTO events(event_id,payload) VALUES ('uncommitted','{}')\"); "
                "os._exit(71)")
        result = subprocess.run([sys.executable, "-B", "-c", code, str(self.path)], timeout=10)  # nosec B603 # fixed crash probe
        self.assertEqual(result.returncode, 71)
        self.assertEqual(LifecycleRegistry(self.path).summary()["events"], 0)

    def test_process_crash_after_commit_allows_exact_replay(self):
        event = key()
        code = ("import json,os,sys; from pathlib import Path; "
                "from worker_lifecycle.store import LifecycleRegistry; "
                "from worker_lifecycle.process import ProcessIdentity; "
                "s=LifecycleRegistry(Path(sys.argv[1])); "
                "s.register(sys.argv[2],sys.argv[3],ProcessIdentity.from_dict(json.load(sys.stdin))); "
                "os._exit(72)")
        result = subprocess.run([sys.executable, "-B", "-c", code, str(self.path), event, self.run],  # nosec B603 # fixed crash probe; identity on stdin
                                input=json.dumps(self.identity.to_dict()), text=True, timeout=10)
        self.assertEqual(result.returncode, 72)
        self.store.register(event, self.run, self.identity)
        self.assertEqual(self.store.summary()["events"], 1)
        self.assertEqual(self.store.summary()["runs"], {"bound": 1})


if __name__ == "__main__":
    unittest.main()
