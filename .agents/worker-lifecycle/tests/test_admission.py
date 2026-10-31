"""Isolated admission transactions; no production launcher or worktree mutation."""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import tempfile
import threading
import unittest
from uuid import uuid4

from worker_lifecycle.admission import AdmissionClosed, AdmissionRegistry
from worker_lifecycle.runtime import adapter_for
from worker_lifecycle.storage import LifecycleRegistry, StoreCapacity, StoreConflict


class AdmissionContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.store = LifecycleRegistry.initialize(self.root / "state")
        self.gate = AdmissionRegistry(self.store)
        self.identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        self.generation = str(uuid4())
        self.open_event = str(uuid4())
        self.gate.open_generation(self.open_event, self.generation, self.root)

    def test_admission_before_close_is_included(self):
        run = str(uuid4())
        self.assertTrue(self.gate.admit(run, self.identity, self.generation))
        self.assertEqual(self.gate.close_generation(str(uuid4()), self.generation), (run,))

    def test_close_before_admission_refuses_without_partial_event(self):
        self.gate.close_generation(str(uuid4()), self.generation)
        before = self.store.summary()
        with self.assertRaises(AdmissionClosed):
            self.gate.admit(str(uuid4()), self.identity, self.generation)
        self.assertEqual(before, self.store.summary())

    def test_replay_after_close_never_grants_second_launch(self):
        run = str(uuid4())
        self.assertTrue(self.gate.admit(run, self.identity, self.generation))
        event = str(uuid4())
        self.gate.close_generation(event, self.generation)
        before = self.store.summary()
        self.assertFalse(self.gate.admit(run, self.identity, self.generation))
        self.gate.open_generation(self.open_event, self.generation, self.root)
        self.assertEqual(self.gate.close_generation(event, self.generation), (run,))
        self.assertEqual(before, self.store.summary())
        with self.assertRaises(AdmissionClosed):
            self.gate.admit(str(uuid4()), self.identity, self.generation)

    def test_new_generation_cannot_bypass_closed_path(self):
        self.gate.close_generation(str(uuid4()), self.generation)
        with self.assertRaises(StoreConflict):
            self.gate.open_generation(str(uuid4()), str(uuid4()), self.root)

    def test_racing_close_and_admit_have_only_serial_outcomes(self):
        barrier = threading.Barrier(2)
        run = str(uuid4())

        def admit():
            barrier.wait(timeout=5)
            try:
                return self.gate.admit(run, self.identity, self.generation)
            except AdmissionClosed:
                return False

        def close():
            barrier.wait(timeout=5)
            return self.gate.close_generation(str(uuid4()), self.generation)

        with ThreadPoolExecutor(max_workers=2) as pool:
            admitted = pool.submit(admit)
            closed = pool.submit(close)
            outcome, pending = admitted.result(timeout=10), closed.result(timeout=10)
        self.assertEqual(pending, (run,) if outcome else ())
        self.assertEqual(self.store.summary()["bindings"], 1 if outcome else 0)

    def test_concurrent_replay_only_one_first_admission(self):
        run = str(uuid4())
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.gate.admit(run, self.identity, self.generation), range(2)))
        self.assertEqual(sorted(results), [False, True])
        self.assertEqual(self.store.summary()["bindings"], 1)

    def test_capacity_failure_rolls_back_admission_and_registration(self):
        with self.store.connection(write=True) as connection:
            connection.execute("UPDATE metadata SET max_events=2")
        before = self.store.summary()
        with self.assertRaises(StoreCapacity):
            self.gate.admit(str(uuid4()), self.identity, self.generation)
        self.assertEqual(before, self.store.summary())

    def test_explicit_upgrade_preserves_observations_without_adopting_them(self):
        run = str(uuid4())
        self.store.register_attempt(run, self.identity, str(uuid4()), str(self.root))
        with self.store.connection(write=True) as connection:
            connection.execute("DROP TABLE generation_admissions")
            connection.execute("PRAGMA user_version=1")
        before = self.store.summary()
        with self.assertRaisesRegex(ValueError, "explicit-schema-upgrade-required"):
            self.gate.close_generation(str(uuid4()), self.generation)
        self.store.upgrade_schema()
        self.store.upgrade_schema()
        self.assertEqual(before, self.store.summary())
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM generation_admissions").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
