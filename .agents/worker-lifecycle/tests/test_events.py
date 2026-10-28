"""Bounded journal admission and stable producer-envelope replay."""

import io
import json
import os
from pathlib import Path
import subprocess  # nosec B404 # bounded, owned test processes only
import sys
import tempfile
import unittest
from uuid import uuid4

from worker_lifecycle.events import ingest, parse_event
from worker_lifecycle.integration_validation import ReportResult
from worker_lifecycle.process import ProcessObservation
from worker_lifecycle.runtime import adapter_for
from worker_lifecycle.registry import reconcile
from worker_lifecycle.storage import LifecycleRegistry, StoreCapacity


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
