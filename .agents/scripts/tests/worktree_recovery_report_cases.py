#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Legacy recovery report cases, without restoration or removal authority."""

from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

import worktree_recovery_legacy_report as legacy_report

HELPER = Path(__file__).resolve().parents[1] / "worktree-archive-helper.sh"


class RecoveryReportCases:
    def test_name_contract_uses_pulse_generator_and_worktree_slug(self):
        producer = (HELPER.parent / "pulse-dispatch-worker-launch.sh").read_text()
        assignment = next(line.strip() for line in producer.splitlines()
                          if line.strip().startswith('_branch="feature/auto-'))
        command = 'issue_number=123; ' + assignment + '; source "$1"; aidevops_branch_slug "$_branch"'
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        result = subprocess.run(  # nosec B603 -- local trusted generator assignment and path helper
            [str(Path(bash).resolve()), "-c", command, "name-contract", str(HELPER.parent / "worktree-paths.sh")],
            capture_output=True, text=True, check=True, timeout=10)
        source = "/fixture/repo-" + result.stdout.strip()
        self.assertEqual(legacy_report.legacy_origin(source, "worktree-helper.sh", "recoverable-cleanup"), "pulse")

    def test_name_contract_rejects_lookalikes_and_profile_sources(self):
        valid = "/fixture/repo-feature-auto-20260101-120000-gh123"
        for source in (valid + "-manual", valid + "/child", valid.replace("-gh123", ""),
                       valid.replace("20260101", "20260231"), valid.replace("gh123", "gh-123"),
                       valid.replace("-feature-auto-", "-fix-auto-"), "relative" + valid):
            with self.subTest(source=source):
                self.assertEqual(legacy_report.legacy_origin(source, "worktree-helper.sh", "recoverable-cleanup"), "unknown")
        self.assertEqual(legacy_report.legacy_origin(valid, "profile-readme-helper.sh", "anything"), "profile")
        self.assertEqual(legacy_report.legacy_origin(valid, "manual.sh", "recoverable-cleanup"), "unknown")

    def test_legacy_policy_boundaries(self):
        week = legacy_report.RETENTION_SECONDS
        cases = [("pulse", week - 1, False, "within-retention"),
                 ("pulse", week, False, "eligible-legacy-pulse"),
                 ("pulse", None, False, "missing-timestamp"),
                 ("pulse", -1, False, "missing-timestamp"),
                 ("manual", week * 2, False, "manual-origin"),
                 ("profile", week * 2, False, "non-pulse-profile"),
                 ("unknown", week * 2, False, "unknown-origin"),
                 ("pulse", week * 2, True, "lifecycle-path")]
        for origin, age, managed, expected in cases:
            with self.subTest(origin=origin, age=age, managed=managed):
                self.assertEqual(legacy_report.legacy_decision(origin, age, managed), expected)

    def test_legacy_report_never_promotes_dispatch_path_to_origin(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bucket = root / "aidevops-worktree-cleanup-fixture"
            metadata = bucket / ".aidevops-worktree-recovery"
            metadata.mkdir(parents=True)
            values = {"format": "aidevops-worktree-recovery-v2",
                      "archive-complete": "aidevops-worktree-recovery-v2",
                      "source-removal-outcome": "removed", "source-real": "/fixture/source",
                      "source-inode": "1:2", "producer": "worktree-helper.sh",
                      "producer-context": "recoverable-cleanup", "created-at": "2020-01-01T00:00:00Z"}
            for name, value in values.items():
                (metadata / name).write_text(value + "\n")
            ledger = root / "ledger.jsonl"
            ledger.write_text(json.dumps({"worktree_path": "/fixture/source"}) + "\n")
            registry = root / "registry.db"
            with closing(sqlite3.connect(registry)) as db:
                db.execute("CREATE TABLE worktree_managed_lifetimes(path TEXT, record TEXT)")
            result = legacy_report.report(root, registry, ledger)
            self.assertEqual(result["reasons"], {"unknown-origin": 1})
            self.assertEqual(result["ages"], {"at-least-7-days": 1})
            self.assertEqual(result["dispatch_path_matches_not_origin_proof"], 1)
            self.assertEqual(result["eligible_legacy_pulse"], 0)
            self.assertFalse(result["deletion_authorized"])
            self.assertNotIn("entries", result)
            entry = legacy_report.report(root, registry, ledger, details=True)["entries"][0]
            self.assertEqual(entry["bucket"], str(bucket))
            self.assertEqual(entry["source_path"], "/fixture/source")
            self.assertEqual(entry["source_inode"], "1:2")
            (metadata / "source-real").write_text("/fixture/repo-feature-auto-20191231-120000-gh123\n")
            self.assertEqual(legacy_report.report(root, registry, ledger)["eligible_legacy_pulse"], 1)
            (metadata / "source-real").write_text("/fixture/source\n")
            record = {"schema": 1, "manager": "pulse", "state": "sealed",
                      "identity": {"path": "/fixture/source", "source_inode": "1:2"}}
            with closing(sqlite3.connect(registry)) as db:
                db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?,?)",
                           ("/fixture/source", json.dumps(record)))
                db.commit()
            self.assertEqual(legacy_report.report(root, registry, ledger)["reasons"], {"lifecycle-path": 1})
            (metadata / "source-inode").write_text("1:3\n")
            self.assertEqual(legacy_report.report(root, registry, ledger)["reasons"], {"lifecycle-path": 1})
            with closing(sqlite3.connect(registry)) as db:
                db.execute("DELETE FROM worktree_managed_lifetimes")
                db.commit()
            (metadata / "producer").write_text("profile-readme-helper.sh\n")
            (metadata / "producer-context").write_text("recovery_path=profile-publication-archive profile_scratch=true\n")
            self.assertEqual(legacy_report.report(root, registry, ledger)["reasons"], {"non-pulse-profile": 1})

    def test_legacy_report_bounded_metadata_and_dates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "metadata"
            path.write_bytes(b"x" * 8193)
            with self.assertRaises(ValueError):
                legacy_report.read_small(path)
            link = root / "link"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                legacy_report.read_small(link)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            with self.assertRaises(ValueError):
                legacy_report.read_small(fifo)
            self.assertIsNone(legacy_report.age_seconds("not-a-date", 100))
            self.assertIsNone(legacy_report.age_seconds("2100-01-01T00:00:00Z", 100))
            self.assertEqual(legacy_report.registry_records(root / "missing.db")[1], "unavailable")
            self.assertFalse((root / "missing.db").exists())
