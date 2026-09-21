#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURE = Path(__file__).parent / "fixtures" / "prospecting" / "routines.json"
sys.path.insert(0, str(SCRIPTS))
import prospecting_alerts as alerts
import prospecting_jobs as jobs


class RoutineTests(unittest.TestCase):
    def setUp(self): self.document = json.loads(FIXTURE.read_text())
    def test_disabled_planning_and_cli_are_non_mutating(self):
        plan = jobs.plan(self.document, now=1720000000)
        self.assertEqual("disabled", plan["jobs"][0]["reason"])
        output = subprocess.run([sys.executable, str(SCRIPTS / "prospecting-routine-helper.py"), "plan", "--input", str(FIXTURE), "--dry-run"], check=True, capture_output=True, text=True)
        self.assertEqual("aidevops.prospecting-routines-plan/v1", json.loads(output.stdout)["schema"])
    def test_replay_reservation_and_unknown_delivery_do_not_duplicate(self):
        job = jobs.plan(self.document, now=1720000000)["jobs"][1]
        receipts = {}; one = jobs.reserve(receipts, job); self.assertIs(one, jobs.reserve(receipts, job))
        rows = alerts.digest(self.document["leads"], set(), set())
        outbox = {}; entry = alerts.enqueue(outbox, "test-project", {"kind":"webhook", "target":"https://alerts.example.test/hook"}, "day-1", rows)
        alerts.transition(entry, "unknown"); self.assertIs(entry, alerts.enqueue(outbox, "test-project", {"kind":"webhook", "target":"https://alerts.example.test/hook"}, "day-1", rows))
    def test_empty_and_unsafe_destinations_are_blocked(self):
        self.assertIsNone(alerts.enqueue({}, "p", {"kind":"email", "target":"ops@example.test"}, "w", []))
        with self.assertRaises(alerts.AlertError): alerts.verified_destination({"kind":"webhook", "target":"http://127.0.0.1/x"})

if __name__ == "__main__": unittest.main()
