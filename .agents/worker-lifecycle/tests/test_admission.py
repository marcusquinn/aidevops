"""Isolated admission transactions; no production launcher or worktree mutation."""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle.admission import (
    AdmissionClosed, AdmissionRegistry, ContentionWait, contention_deadline,
    within_contention_deadline,
)
from worker_lifecycle.process import ProcessObservation
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

    def test_quiescent_close_requires_every_bound_run_to_end(self):
        runs = (str(uuid4()), str(uuid4()))
        for run in runs:
            self.gate.admit(run, self.identity, self.generation)
        self.store.observe(str(uuid4()), runs[0], 2, ProcessObservation("ended", "pid-absent"))
        with self.assertRaisesRegex(StoreConflict, "generation-not-quiescent"):
            self.gate.close_generation(str(uuid4()), self.generation, expected_ended_runs=runs)
        self.store.observe(str(uuid4()), runs[1], 2, ProcessObservation("ended", "pid-absent"))
        self.assertEqual(self.gate.close_generation(
            str(uuid4()), self.generation, expected_ended_runs=runs), ())
        with self.assertRaises(AdmissionClosed):
            self.gate.admit(str(uuid4()), self.identity, self.generation)

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

    def test_replays_do_not_require_writer_admission(self):
        run = str(uuid4())
        self.assertTrue(self.gate.admit(run, self.identity, self.generation))
        before = self.store.summary()
        with self.store.connection(write=True):
            self.gate.open_generation(self.open_event, self.generation, self.root)
            self.assertFalse(self.gate.admit(run, self.identity, self.generation))
            # A new owner cannot use the read-only replay path to bypass a lock.
            with self.assertRaises(sqlite3.OperationalError):
                self.gate.admit(str(uuid4()), self.identity, self.generation)
        self.assertEqual(before, self.store.summary())

    def test_replay_checks_payload_even_while_writer_is_busy(self):
        run = str(uuid4())
        self.gate.admit(run, self.identity, self.generation)
        with self.store.connection(write=True):
            with self.assertRaisesRegex(StoreConflict, "event-id-payload-conflict"):
                self.gate.admit(run, self.identity, self.generation, str(self.root))
            with self.assertRaisesRegex(StoreConflict, "event-id-payload-conflict"):
                self.gate.open_generation(self.open_event, str(uuid4()), self.root)

    def blocked(self):
        """An independent connection holding the registry writer."""
        blocker = self.store._connect()
        blocker.execute("BEGIN IMMEDIATE")
        self.addCleanup(blocker.close)
        return blocker

    def admit_waiting(self, run, **wait):
        """Admit through the bounded contention wait used by the launcher."""
        return within_contention_deadline(
            lambda: self.gate.admit(run, self.identity, self.generation), ContentionWait(**wait))

    def test_transient_contention_recovers_within_deadline(self):
        """GH#36921: a writer released before the deadline admits exactly once."""
        blocker, run, retries = self.blocked(), str(uuid4()), []
        admitted = self.admit_waiting(
            run, deadline=10,
            on_retry=lambda attempt, error: retries.append((attempt, str(error))),
            sleep=lambda _pause: blocker.rollback())
        self.assertTrue(admitted)
        self.assertEqual(retries, [(1, "database is locked")])
        self.assertEqual(self.store.summary()["bindings"], 1)
        self.assertFalse(self.admit_waiting(run))

    def test_persistent_contention_fails_closed_at_deadline(self):
        """Contention outlasting the deadline denies without any partial admission."""
        self.blocked()
        before, pauses = self.store.summary(), []
        with self.assertRaisesRegex(sqlite3.OperationalError, "database is locked"):
            self.admit_waiting(str(uuid4()), deadline=0.5, sleep=pauses.append)
        self.assertEqual(pauses, [])
        self.assertEqual(before, self.store.summary())

    def test_generation_closed_during_contention_never_admits(self):
        """Every retry rechecks the gate under the writer; a racing close wins."""
        blocker = self.blocked()

        def close(_pause):
            blocker.execute("UPDATE generation_admissions SET state='closed' WHERE generation_id=?",
                            (self.generation,))
            blocker.commit()

        with self.assertRaises(AdmissionClosed):
            self.admit_waiting(str(uuid4()), deadline=10, sleep=close)
        self.assertEqual(self.store.summary()["bindings"], 0)

    def test_lost_acknowledgement_retry_is_never_execution_authority(self):
        """A committed attempt reported as busy replays as False on retry."""
        run, native, calls = str(uuid4()), self.gate.admit, []

        def committed_then_busy(*arguments):
            calls.append(native(*arguments))
            if len(calls) == 1:
                raise sqlite3.OperationalError("database is locked")
            return calls[-1]

        self.gate.admit = committed_then_busy
        self.assertFalse(self.admit_waiting(run, deadline=10, sleep=lambda _pause: None))
        self.assertEqual(calls, [True, False])
        self.assertEqual(self.store.summary()["bindings"], 1)

    def test_non_contention_database_errors_are_not_retried(self):
        """Only the contention category waits; other SQLite failures deny at once."""
        pauses = []

        def failing(*_arguments):
            raise sqlite3.OperationalError("disk I/O error")

        self.gate.admit = failing
        with self.assertRaisesRegex(sqlite3.OperationalError, "disk I/O error"):
            self.admit_waiting(str(uuid4()), deadline=10, sleep=pauses.append)
        self.assertEqual(pauses, [])

    def test_admission_wait_configuration_is_bounded(self):
        """Invalid or unbounded waits are rejected rather than silently applied."""
        for value, expected in (("0", 0.0), ("12.5", 12.5)):
            with patch.dict(os.environ, {"AIDEVOPS_LIFECYCLE_ADMISSION_WAIT_SECONDS": value}):
                self.assertEqual(contention_deadline(), expected)
        for value in ("-1", "301", "nan", "inf", "soon"):
            with patch.dict(os.environ, {"AIDEVOPS_LIFECYCLE_ADMISSION_WAIT_SECONDS": value}):
                with self.assertRaisesRegex(ValueError, "invalid-admission-wait"):
                    contention_deadline()

    def test_capacity_failure_rolls_back_admission_and_registration(self):
        with self.store.connection(write=True) as connection:
            connection.execute("UPDATE metadata SET max_events=2")
        before = self.store.summary()
        with self.assertRaises(StoreCapacity):
            self.gate.admit(str(uuid4()), self.identity, self.generation)
        self.assertEqual(before, self.store.summary())

    def test_full_store_automatically_archives_before_new_admission(self):
        ended = str(uuid4())
        self.gate.admit(ended, self.identity, self.generation)
        self.store.observe(str(uuid4()), ended, 2, ProcessObservation("ended", "pid-absent"))
        with self.store.connection(write=True) as connection:
            connection.execute("UPDATE events SET recorded_at='2000-01-01T00:00:00.000Z'")
            connection.execute("UPDATE metadata SET max_events=5")
        self.assertEqual(self.store.summary()["event_headroom"], 0)
        self.assertTrue(self.gate.admit(str(uuid4()), self.identity, self.generation))
        self.assertEqual(self.store.summary()["runs"], {"bound": 1, "ended": 1})
        self.assertEqual(self.store.summary()["events"], 4)  # open + new admit/register/bind
        self.assertEqual(len(list(self.store.directory.glob("events-archive-*"))), 1)
        with self.assertRaisesRegex(StoreConflict, "run-already-registered"):
            self.gate.admit(ended, self.identity, self.generation)

    def test_compaction_keeps_evidence_shared_with_bound_owner(self):
        ended, live = str(uuid4()), str(uuid4())
        self.gate.admit(ended, self.identity, self.generation)
        self.gate.admit(live, self.identity, self.generation)
        self.store.observe(str(uuid4()), ended, 2, ProcessObservation("ended", "pid-absent"))
        before = self.store.summary()
        self.assertEqual(self.store.compact(age=0, apply=True)["archived_events"], 0)
        self.assertEqual(self.store.summary(), before)

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
        self.assertEqual({**before, "schema_version": 2, "upgrade_required": False},
                         self.store.summary())
        backups = list(self.store.directory.glob("schema-1-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(LifecycleRegistry(backups[0]).summary(), before)
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM generation_admissions").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
