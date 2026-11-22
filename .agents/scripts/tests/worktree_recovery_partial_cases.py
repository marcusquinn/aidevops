#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Partial capture evidence cases using the shared archive lifecycle fixture."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
import subprocess
from unittest.mock import patch

import worktree_recovery_producer as producer_engine
import worktree_recovery_partials as partial_engine


class PartialCases:
    def test_partial_capture_records_fingerprint_before_payload(self):
        def interrupted(lock, *arguments):
            self.assertEqual(arguments[0], "archive")
            journals = list(self.archives.glob(".producer-transactions/*/journal.json"))
            self.assertEqual(len(journals), 1)
            record = json.loads(journals[0].read_text())
            self.assertEqual(record["phase"], "capturing")
            self.assertEqual(record["source"], producer_engine.source_state(self.work))
            self.assertIn(record["source"]["snapshot"]["schema"], (3, 4))
            raise subprocess.CalledProcessError(1, ["archive"])

        with patch.dict(os.environ, self.env), \
                patch.object(producer_engine, "archive_command", side_effect=interrupted), \
                self.assertRaises(subprocess.CalledProcessError):
            producer_engine.prepare(self.work, self.archives, "test.sh", "interruption")

    def test_partial_sweep_retains_missing_or_changed_content_evidence(self):
        for change in ("edited", "deleted", "head", "missing-snapshot", "schema2"):
            with self.subTest(change=change), patch.dict(os.environ, self.env):
                root = self.archives / change
                untracked = self.work / "partial-untracked"
                untracked.write_bytes(b"only copy in partial after deletion\n")
                current, directory, output = producer_engine.reservation(self.work, root)
                record = producer_engine.reserve(current, directory, output, "test.sh", change)
                partial = output / "owner__repo" / "unattributed" / "20260101T000000Z"
                partial.mkdir(parents=True)
                payload = partial / "untracked.tar.gz"
                payload.write_bytes(untracked.read_bytes())
                if change == "edited":
                    untracked.write_bytes(b"changed content\n")
                elif change == "deleted":
                    untracked.unlink()
                elif change == "head":
                    self.git(self.work, "commit", "--allow-empty", "-qm", "head drift")
                else:
                    if change == "missing-snapshot":
                        record["source"].pop("snapshot")
                    else:
                        record["source"]["snapshot"] = producer_engine.git_snapshot(
                            self.work, include_untracked=False)
                    producer_engine.publish(directory / "journal.json", record)
                for mode in ("dry-run", "apply"):
                    swept = self.producer("sweep-partials", root, mode)
                    self.assertEqual(swept.stdout, b"")
                    self.assertIn(b"retained:source-changed", swept.stderr)
                    self.assertEqual(payload.read_bytes(), b"only copy in partial after deletion\n")
                if change in ("edited", "deleted", "head"):
                    with self.assertRaisesRegex(ValueError, "source-drift"):
                        producer_engine.reserve(producer_engine.source_state(self.work), directory,
                                                output, "test.sh", change)
                elif change == "missing-snapshot":
                    resumed = producer_engine.reserve(producer_engine.source_state(self.work), directory,
                                                      output, "test.sh", change)
                    self.assertNotIn("snapshot", resumed["source"])

    def test_partial_sweep_reports_removals_before_failure(self):
        with patch.dict(os.environ, self.env):
            current, directory, output = producer_engine.reservation(self.work, self.archives)
            producer_engine.reserve(current, directory, output, "test.sh", "partial-failure")
        partials = [output / "owner__repo" / "unattributed" / stamp
                    for stamp in ("20260101T000000Z", "20260102T000000Z")]
        for partial in partials:
            partial.mkdir(parents=True, exist_ok=True)
        remove = partial_engine.remove_partial

        def fail_second(output_root, capture_dir):
            if capture_dir == partials[1]:
                raise OSError("simulated removal failure")
            remove(output_root, capture_dir)

        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, self.env), \
                patch.object(partial_engine, "remove_partial", side_effect=fail_second), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            status = producer_engine.sweep_partials(self.archives, True)
        self.assertEqual(status, 1)
        self.assertEqual(stdout.getvalue(), f"removed\t{partials[0]}\n")
        self.assertIn("retained:producer:evidence-unavailable", stderr.getvalue())
        self.assertFalse(partials[0].exists())
        self.assertTrue(partials[1].is_dir())
