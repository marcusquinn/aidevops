"""Bounded journal admission and stable producer-envelope replay."""

import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # bounded, owned test processes only
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle.events import ingest, parse_event
from worker_lifecycle.integration_validation import ReportResult
from worker_lifecycle.process import ProcessObservation
from worker_lifecycle.runtime import adapter_for
from worker_lifecycle.registry import reconcile
from worker_lifecycle.storage import (DEFAULT_MAX_EVENTS, LEGACY_DEFAULT_MAX_EVENTS, LifecycleRegistry,
                                      StoreCapacity, StoreConflict, encode)


class EventContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve() / "state"
        self.store = LifecycleRegistry.initialize(self.path, max_events=3)
        self.adapter = adapter_for(self.store.installation_id())

    def envelope(self, pid):
        return {"schema": 1, "type": "register", "event_id": str(uuid4()),
                "run_id": str(uuid4()), "identity": self.adapter.capture(pid).to_dict()}

    def test_capacity_preserves_evidence_and_exact_replays(self):
        events = [self.envelope(os.getpid()) for _ in range(3)]
        for event in events:
            ingest(self.store, json.dumps(event))
        before = self.store.summary()
        self.assertTrue(before["journal_full"])
        self.assertTrue(before["last_event_at"].endswith("Z"))
        ingest(self.store, json.dumps(events[0]))
        self.assertEqual(self.store.summary(), before)
        with self.assertRaises(StoreCapacity):
            ingest(self.store, json.dumps(self.envelope(os.getpid())))
        self.assertEqual(self.store.summary(), before)

    def stored_limit(self):
        with self.store.connection() as connection:
            return connection.execute("SELECT max_events FROM metadata").fetchone()[0]

    def test_new_store_defaults_to_raised_limit(self):
        store = LifecycleRegistry.initialize(Path(self.temp.name).resolve() / "default")
        self.assertEqual(store.summary()["event_limit"], DEFAULT_MAX_EVENTS)

    def test_full_legacy_default_store_is_lifted_on_next_write(self):
        # GH#36620: one bulk transaction reaches the legacy cap without 10,000 fsyncs.
        with self.store.connection(write=True) as connection:
            connection.executemany("INSERT INTO events(event_id,payload) VALUES (?,?)",
                                   [(str(uuid4()), "{}") for _ in range(LEGACY_DEFAULT_MAX_EVENTS)])
            connection.execute("UPDATE metadata SET max_events=?", (LEGACY_DEFAULT_MAX_EVENTS,))
        before = self.store.summary()
        self.assertEqual((before["events"], before["event_limit"], before["journal_full"]),
                         (LEGACY_DEFAULT_MAX_EVENTS, DEFAULT_MAX_EVENTS, False))
        self.assertEqual(self.stored_limit(), LEGACY_DEFAULT_MAX_EVENTS, "status must not write")
        ingest(self.store, json.dumps(self.envelope(os.getpid())))
        self.assertEqual(self.store.summary()["events"], LEGACY_DEFAULT_MAX_EVENTS + 1)
        self.assertEqual(self.stored_limit(), DEFAULT_MAX_EVENTS)

    def test_explicit_limit_is_not_lifted(self):
        for _ in range(3):
            ingest(self.store, json.dumps(self.envelope(os.getpid())))
        with self.assertRaises(StoreCapacity):
            ingest(self.store, json.dumps(self.envelope(os.getpid())))
        self.assertEqual((self.stored_limit(), self.store.summary()["event_limit"]), (3, 3))

    def test_observation_at_capacity_cannot_partially_end_run(self):
        events = [self.envelope(os.getpid()) for _ in range(3)]
        for event in events:
            ingest(self.store, json.dumps(event))
        with self.assertRaises(StoreCapacity):
            self.store.observe(str(uuid4()), events[0]["run_id"], 1, ProcessObservation("ended", "pid-absent"))
        self.assertEqual(self.store.summary()["runs"], {"bound": 3})

    def test_replay_after_process_exit_does_not_recapture_identity(self):
        code = "import select,sys; ready,_,_=select.select([sys.stdin],[],[],10); sys.stdin.read(1) if ready else None"
        with subprocess.Popen([sys.executable, "-I", "-B", "-c", code], stdin=subprocess.PIPE) as child:  # nosec B603 # fixed probe code
            try:
                event = self.envelope(child.pid)
            finally:
                child.stdin.close()
                child.wait(timeout=12)
        payload = json.dumps(event)
        ingest(self.store, payload)
        self.assertEqual(reconcile(self.store)["processed"], 1)
        ingest(self.store, payload)
        self.assertEqual(self.store.summary()["runs"], {"ended": 1})
        self.assertEqual(self.store.summary()["events"], 2)

    def test_cli_ingestion_and_replay(self):
        payload = json.dumps(self.envelope(os.getpid()))
        command = [sys.executable, "-B", "-m", "worker_lifecycle.registry",
                   "--state-dir", str(self.path), "ingest"]
        for _ in range(2):
            result = subprocess.run(command, input=payload, text=True,  # nosec B603 # fixed registry CLI; data on stdin
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(json.loads(result.stdout)["events"], 1)

    def test_invalid_envelopes_never_write(self):
        event = self.envelope(os.getpid())
        invalid = [json.dumps(dict(event, schema=True)), json.dumps(dict(event, type="observe")),
                   json.dumps(dict(event, extra="ignored?")), "[1,2]", " " * 16385,
                   '{"schema":1,"schema":1}']
        for raw in invalid:
            with self.subTest(raw=raw[:50]), self.assertRaises(ValueError):
                ingest(self.store, raw)
        self.assertEqual(self.store.summary()["events"], 0)

    def test_missing_schema_rejected(self):
        with self.assertRaises(ValueError):
            parse_event("{}")

    def ended_event(self):
        event = self.envelope(os.getpid())
        ingest(self.store, json.dumps(event))
        self.store.observe(str(uuid4()), event["run_id"], 1, ProcessObservation("ended", "pid-absent"))
        return event

    def cli(self, *arguments):
        command = [sys.executable, "-B", "-m", "worker_lifecycle.registry",
                   "--state-dir", str(self.path), *arguments]
        result = subprocess.run(command, text=True, capture_output=True, timeout=10)  # nosec B603 # fixed CLI
        self.assertEqual(result.returncode, 0, result.stdout)
        return json.loads(result.stdout)

    def test_compact_cli_preview_archive_checksum_and_replay(self):
        event = self.ended_event()
        before = self.store.summary()
        self.assertEqual(self.cli("compact", "--min-age-seconds", "0")["eligible_events"], 2)
        self.assertEqual(self.store.summary(), before)
        self.assertEqual(list(self.path.glob("events-archive-*")), [])
        result = self.cli("compact", "--min-age-seconds", "0", "--apply")
        archive = self.path / result["archive"]
        document = json.loads(archive.read_text())
        self.assertEqual(document["sha256"], hashlib.sha256(encode(document["evidence"]).encode()).hexdigest())
        self.assertIn(event["event_id"], [row["event_id"] for row in document["evidence"]["events"]])
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.store.summary()["events"], 0)
        self.assertEqual(self.store.summary()["runs"], {"ended": 1})
        with self.assertRaisesRegex(StoreConflict, "run-already-registered"):
            ingest(self.store, json.dumps(event))
        changed = dict(event, run_id=str(uuid4()))
        with self.assertRaisesRegex(StoreConflict, "event-id-payload-conflict"):
            ingest(self.store, json.dumps(changed))
        self.assertEqual(self.store.summary()["events"], 0)

    def test_age_and_archive_failure_preserve_journal(self):
        self.ended_event()
        self.assertEqual(self.store.compact(apply=True)["archived_events"], 0)
        before = self.store.summary()
        with patch("worker_lifecycle.storage.os.fsync", side_effect=OSError("archive-unavailable")):
            with self.assertRaises(OSError):
                self.store.compact(age=0, apply=True)
        self.assertEqual(self.store.summary(), before)

    def test_capacity_raise_requires_apply_and_verified_backup(self):
        ingest(self.store, json.dumps(self.envelope(os.getpid())))
        self.assertTrue(self.cli("raise-capacity", "--max-events", "10")["dry_run"])
        self.assertEqual(self.stored_limit(), 3)
        result = self.cli("raise-capacity", "--max-events", "10", "--apply")
        self.assertEqual(self.stored_limit(), 10)
        with sqlite3.connect(self.path / result["backup"]) as connection:
            self.assertEqual(connection.execute("SELECT max_events FROM metadata").fetchone()[0], 3)
            self.assertEqual(connection.execute("SELECT count(*) FROM events").fetchone()[0], 1)
            self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        for maximum in (9, 10, 100001, True):
            with self.assertRaises(ValueError):
                self.store.raise_capacity(maximum, apply=True)

    def test_capacity_raise_cannot_lower_effective_legacy_limit(self):
        with self.store.connection(write=True) as connection:
            connection.execute("UPDATE metadata SET max_events=?", (LEGACY_DEFAULT_MAX_EVENTS,))
        with self.assertRaises(ValueError):
            self.store.raise_capacity(20000, apply=True)
        self.assertEqual(self.store.summary()["event_limit"], DEFAULT_MAX_EVENTS)
        self.store.raise_capacity(DEFAULT_MAX_EVENTS, apply=True)
        self.assertEqual(self.stored_limit(), DEFAULT_MAX_EVENTS)

    def test_status_reports_insufficient_three_event_headroom(self):
        ingest(self.store, json.dumps(self.envelope(os.getpid())))
        status = self.cli("status")
        self.assertEqual(status["event_headroom"], 2)
        self.assertEqual(status["admission_event_need"], 3)
        self.assertTrue(status["journal_full"])

    def test_subtest_failures_are_reported_without_private_parameters(self):
        class Probe(unittest.TestCase):
            def runTest(self):
                with self.subTest(path="private-sentinel"):
                    self.fail("private-sentinel")
                with self.subTest(path="private-sentinel"):
                    raise OSError("private-sentinel")

        result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=ReportResult).run(Probe())
        self.assertEqual((len(result.failures), len(result.errors)), (1, 1))
        self.assertEqual([check["status"] for check in result.checks], ["failed", "error"])
        self.assertNotIn("private-sentinel", json.dumps(result.checks))


if __name__ == "__main__":
    unittest.main()
