"""Schema upgrade contracts on disposable registries, including the public CLI."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # fixed local CLI in disposable fixtures
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle.runtime import adapter_for
from worker_lifecycle.storage import LifecycleRegistry
from worker_lifecycle.upgrade import upgrade_registry


class UpgradeContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="registry-upgrade-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.store = LifecycleRegistry.initialize(self.root / "state")
        with self.store.connection(write=True) as connection:
            connection.execute("DROP TABLE generation_admissions")
            connection.execute("PRAGMA user_version=1")

    def cli(self, *arguments):
        return subprocess.run(  # nosec B603 # owned Python entry point, no shell
            [sys.executable, "-E", "-s", "-B", "-m", "worker_lifecycle.registry",
             "--state-dir", str(self.store.directory), *arguments],
            cwd=Path(__file__).resolve().parents[1], capture_output=True,
            text=True, timeout=15,
        )

    def test_status_is_read_only_and_manual_upgrade_is_idempotent(self):
        result = self.cli("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["upgrade_required"])
        self.assertEqual(list(self.store.directory.glob("schema-1-backup-*")), [])
        result = self.cli("upgrade")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "upgraded")
        self.assertTrue((Path(payload["backup_dir"]) / "registry.sqlite3").is_file())
        result = self.cli("upgrade")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "already-current")
        self.assertEqual(len(list(self.store.directory.glob("schema-1-backup-*"))), 1)

    def test_live_runs_and_wal_history_survive_without_historical_admission(self):
        identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        # Keep a connection open so committed history remains in WAL at backup time.
        with closing(sqlite3.connect(self.store.path)) as reader:
            reader.execute("SELECT * FROM metadata").fetchall()
            self.store.register_attempt(str(uuid4()), identity, str(uuid4()), "/historical")
            before = self.store.summary()
            self.assertGreater(Path(str(self.store.path) + "-wal").stat().st_size, 0)
            result = upgrade_registry(self.store)
        backup = LifecycleRegistry(Path(result["backup_dir"]))
        self.assertEqual(backup.summary(), before)
        self.assertEqual(backup.installation_id(), identity.installation_id)
        after = self.store.summary()
        self.assertEqual(after, {**before, "schema_version": 2, "upgrade_required": False})
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM generation_admissions").fetchone()[0], 0)
        self.assertEqual(backup.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(backup.path.stat().st_mode & 0o777, 0o600)

    def test_pulse_reconcile_upgrades_automatically(self):
        result = self.cli("reconcile", "--limit", "100")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["processed"], 0)
        self.assertFalse(self.store.summary()["upgrade_required"])
        self.assertEqual(len(list(self.store.directory.glob("schema-1-backup-*"))), 1)

    def test_concurrent_upgrades_create_only_one_backup(self):
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(upgrade_registry, self.store) for _ in range(2)]
            results = [future.result(timeout=10)["status"] for future in futures]
        self.assertCountEqual(results, ["upgraded", "already-current"])
        self.assertEqual(len(list(self.store.directory.glob("schema-1-backup-*"))), 1)

    def test_backup_failure_prevents_migration(self):
        before = self.store.summary()
        with patch("worker_lifecycle.upgrade._sync", side_effect=OSError("sync-failed")):
            with self.assertRaises(OSError):
                upgrade_registry(self.store)
        self.assertEqual(self.store.summary(), before)
        self.assertEqual(upgrade_registry(self.store)["status"], "upgraded")

    def test_migration_failure_rolls_back_and_retains_backup(self):
        before = self.store.summary()
        original = self.store._create_admissions

        def fail_after_create(connection):
            original(connection)
            raise sqlite3.OperationalError("injected failure")

        with patch.object(self.store, "_create_admissions", side_effect=fail_after_create):
            with self.assertRaises(sqlite3.OperationalError):
                upgrade_registry(self.store)
        self.assertEqual(self.store.summary(), before)
        backups = list(self.store.directory.glob("schema-1-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(LifecycleRegistry(backups[0]).summary(), before)
        self.assertEqual(upgrade_registry(self.store)["status"], "upgraded")

    def test_existing_backup_target_is_not_overwritten(self):
        before = self.store.summary()
        result = self.cli("upgrade", "--backup-dir", str(self.store.directory))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.store.summary(), before)

    def test_unsupported_schema_is_not_repaired(self):
        with self.store.connection(write=True) as connection:
            connection.execute("PRAGMA user_version=99")
        result = self.cli("upgrade")
        self.assertEqual(result.returncode, 2)
        with closing(sqlite3.connect(self.store.path)) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 99)
        self.assertEqual(list(self.store.directory.glob("schema-1-backup-*")), [])
