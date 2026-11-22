#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Isolated runtime regression cases for the production CLI, no host cleanup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(sys.argv.pop())
MANIFEST = '.aidevops-task-temp.json'


class CleanupTests(unittest.TestCase):
    def setUp(self):
        base = os.environ.get('AIDEVOPS_TEMP_DIR', str(Path.home() / '.aidevops/.agent-workspace/tmp'))
        os.makedirs(base, mode=0o700, exist_ok=True)
        self.base = Path(tempfile.mkdtemp(prefix='cleanup-test-', dir=base))
        self.root = self.base / 'tmp'
        self.root.mkdir(mode=0o700)
        self.env = dict(os.environ, AIDEVOPS_TEMP_DIR=str(self.root),
                        AIDEVOPS_LOG_DIR=str(self.base / 'logs'),
                        XDG_DATA_HOME=str(self.base / 'data'),
                        AIDEVOPS_TMP_MIN_FREE_PERCENT='0', AIDEVOPS_TMP_MIN_FREE_GB='0')
        self.owner = subprocess.Popen(['bash', '-c', 'read -r line'], stdin=subprocess.PIPE)
        # A backend double confines all moves to this test's private directory.
        bin_dir = self.base / 'bin'
        bin_dir.mkdir()
        backend = bin_dir / 'trash'
        backend.write_text('#!/usr/bin/env python3\nimport os,shutil,sys\n'
                           'for p in sys.argv[1:]:\n'
                           ' shutil.move(p, os.path.join(os.environ["TEST_TRASH"],os.path.basename(p)))\n')
        backend.chmod(0o700)
        (self.base / 'trash').mkdir()
        self.env.update(PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                        TEST_TRASH=str(self.base / 'trash'))

    def tearDown(self):
        self.stop_owner()
        shutil.rmtree(self.base)

    def stop_owner(self):
        if self.owner.poll() is None:
            self.owner.terminate()
        self.owner.wait(timeout=5)
        self.owner.stdin.close()

    def create(self, name='example', age='24h'):
        result = subprocess.run(['bash', str(SCRIPTS / 'task-temp-helper.sh'), 'create', name,
                                 '--max-age', age, '--owner-pid', str(self.owner.pid)],
                                env=self.env, check=True, text=True, capture_output=True)
        return Path(result.stdout.strip())

    def cross_device_trash(self):
        if sys.platform.startswith('linux'):
            # Only device evidence uses this path; the backend double still
            # confines every move to self.base, never the real user Trash.
            other = Path('/dev/shm')
            if not other.is_dir() or other.stat().st_dev == self.root.stat().st_dev:
                self.skipTest('cross-device Trash requires a second filesystem')
            self.env['XDG_DATA_HOME'] = str(other)

    def cleanup(self, *args):
        return subprocess.run(['bash', str(SCRIPTS / 'system-cleanup.sh'), *args],
                              env=self.env, check=True, text=True, capture_output=True, timeout=10).stdout

    def old(self, path):
        stamp = time.time() - 30 * 86400
        for parent, dirs, files in os.walk(path):
            for name in dirs + files:
                os.utime(Path(parent) / name, (stamp, stamp), follow_symlinks=False)
        os.utime(path, (stamp, stamp))

    def test_owner_exit_dry_run_and_force(self):
        path = self.create()
        self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        data = json.loads((path / MANIFEST).read_text())
        self.assertEqual(data['expires'] - data['created'], 86400)
        self.stop_owner()
        linux = sys.platform.startswith('linux')
        action = 'delete' if linux else 'trash'
        self.assertIn(f'Would {action}: {path}', self.cleanup('--dry-run'))
        self.assertTrue(path.exists())
        result = self.cleanup('--force')
        self.assertIn('pressure=0', result)
        self.assertIn('deleted=1' if linux else 'trashed=1', result)
        self.assertFalse(path.exists())
        self.assertEqual((self.base / 'trash' / path.name).exists(), not linux)

    def test_cross_device_keeps_trash(self):
        self.cross_device_trash()
        path = self.create()
        self.stop_owner()
        self.assertIn(f'Would trash: {path}', self.cleanup('--dry-run'))
        result = self.cleanup('--force')
        self.assertIn('trashed=1 deleted=0', result)
        self.assertTrue((self.base / 'trash' / path.name).exists())

    def test_existing_same_device_trash_is_not_emptied(self):
        trash = Path(self.env['XDG_DATA_HOME']) / 'Trash'
        trash.mkdir(parents=True)
        unrelated = trash / 'unrelated'
        unrelated.write_text('user-owned Trash is not ours to empty')
        path = self.create()
        self.stop_owner()
        self.cleanup('--force')
        self.assertFalse(path.exists())
        self.assertTrue(unrelated.exists())

    def test_live_owner_expiry_and_pressure_veto(self):
        path = self.create(age='1s')
        data = json.loads((path / MANIFEST).read_text())
        data.update(created=1, expires=2)
        (path / MANIFEST).write_text(json.dumps(data))
        self.env['AIDEVOPS_TMP_MIN_FREE_PERCENT'] = '100'
        self.assertNotIn(str(path), self.cleanup('--force'))
        self.assertTrue(path.exists())

    def test_pid_generation_mismatch_and_expired(self):
        path = self.create()
        data = json.loads((path / MANIFEST).read_text())
        data.update(start='previous-generation', created=1, expires=2)
        (path / MANIFEST).write_text(json.dumps(data))
        self.cleanup('--force')
        self.assertFalse(path.exists())

    def test_legacy_lock_age_and_recent_descendant(self):
        stale = self.root / 'stale'
        stale.mkdir()
        (stale / 'old.lease').touch()
        (stale / 'old.lock').touch()
        self.old(stale)
        fresh = self.root / 'fresh'
        fresh.mkdir()
        self.old(fresh)
        (fresh / 'recent.lease').touch()
        self.cleanup('--force')
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())

    def test_live_lease_and_exclusions(self):
        owned = self.create()
        legacy = self.root / 'legacy'
        legacy.mkdir()
        shutil.copy(owned / MANIFEST, legacy / 'owner.lease')
        self.old(legacy)
        for name in ('session-checkpoints', 'locks', 'pulse', 'repository-campaigns'):
            path = self.root / name
            path.mkdir()
            self.old(path)
        self.cleanup('--force')
        self.assertTrue(legacy.exists())
        self.assertTrue(all((self.root / name).exists() for name in
                            ('session-checkpoints', 'locks', 'pulse', 'repository-campaigns')))

    def test_pressure_deletes_largest_first(self):
        if not sys.platform.startswith('linux'):
            self.skipTest('Linux pressure deletion policy')
        small, large = self.create('small'), self.create('large')
        (large / 'payload').write_bytes(b'x' * 65536)
        self.stop_owner()
        self.env['AIDEVOPS_TMP_MIN_FREE_GB'] = '1000000000'
        preview = self.cleanup('--dry-run')
        self.assertLess(preview.index(str(large)), preview.index(str(small)))
        self.assertIn('Would delete:', preview)
        result = self.cleanup('--force', '--batch-size', '1')
        self.assertIn('deleted=2', result)
        self.assertFalse(small.exists() or large.exists())
        self.assertFalse(any((self.base / 'trash').iterdir()))

    def test_malformed_and_symlink_manifests_retained(self):
        path = self.create()
        (path / MANIFEST).write_text('[]')
        self.old(path)
        self.stop_owner()
        self.cleanup('--force')
        self.assertTrue(path.exists())
        (path / MANIFEST).unlink()
        (path / MANIFEST).symlink_to(self.base / 'missing')
        self.cleanup('--force')
        self.assertTrue(path.exists())

    def test_root_symlink_rejected(self):
        link = self.base / 'redirect'
        link.symlink_to(self.root, target_is_directory=True)
        self.env['AIDEVOPS_TEMP_DIR'] = str(link / 'tmp')
        with self.assertRaises(subprocess.CalledProcessError):
            self.cleanup('--force')

    def test_top_level_and_nested_live_leases(self):
        owned = self.create()
        lease = self.root / 'owner.lease'
        shutil.copy(owned / MANIFEST, lease)
        self.old(lease)
        parent = self.create('parent')
        data = json.loads((parent / MANIFEST).read_text())
        data['start'] = 'dead-generation'
        (parent / MANIFEST).write_text(json.dumps(data))
        shutil.copy(owned / MANIFEST, parent / 'live.lease')
        self.env['AIDEVOPS_TMP_MIN_FREE_PERCENT'] = '100'
        self.cleanup('--force')
        self.assertTrue(lease.exists() and parent.exists())

    def test_fifo_manifest_does_not_block(self):
        path = self.create()
        (path / MANIFEST).unlink()
        os.mkfifo(path / MANIFEST)
        self.stop_owner()
        self.cleanup('--force', '--max-seconds', '1')
        self.assertTrue(path.exists())

    def test_bounded_backend_and_backlog_progress(self):
        for n in range(10):
            self.create(f'backlog-{n}')
        self.stop_owner()
        self.cleanup('--force', '--max-seconds', '1', '--batch-size', '2')
        self.assertFalse(any(self.root.iterdir()))
        # A hung trash process must not consume the pulse's whole preflight.
        self.cross_device_trash()
        self.owner = subprocess.Popen(['bash', '-c', 'read -r line'], stdin=subprocess.PIPE)
        path = self.create('slow')
        self.stop_owner()
        (self.base / 'bin/trash').write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n')
        result = self.cleanup('--force', '--max-seconds', '1')
        self.assertIn('budget_exhausted=1', result)
        self.assertTrue(path.exists())

    def test_failed_partial_batch_uses_gio(self):
        self.cross_device_trash()
        paths = [self.create(f'fallback-{n}') for n in range(3)]
        self.stop_owner()
        (self.base / 'bin/trash').write_text(
            '#!/usr/bin/env python3\nimport os,shutil,sys\n'
            'shutil.move(sys.argv[1], os.path.join(os.environ["TEST_TRASH"],os.path.basename(sys.argv[1])))\n'
            'sys.exit(1)\n')
        gio = self.base / 'bin/gio'
        gio.write_text('#!/usr/bin/env python3\nimport os,shutil,sys\n'
                       'assert sys.argv[1] == "trash"\n'
                       'for p in sys.argv[2:]:\n'
                       ' shutil.move(p, os.path.join(os.environ["TEST_TRASH"],os.path.basename(p)))\n')
        gio.chmod(0o700)
        result = self.cleanup('--force', '--max-seconds', '2')
        self.assertIn('trashed=3', result)
        self.assertIn('failed=0', result)
        self.assertTrue(all((self.base / 'trash' / path.name).exists() for path in paths))

    def test_failed_batches_retry_individually_and_retain_failure(self):
        self.cross_device_trash()
        paths = [self.create(name) for name in ('good', 'blocked')]
        self.stop_owner()
        (self.base / 'bin/trash').write_text(
            '#!/usr/bin/env python3\nimport os,shutil,sys\n'
            'if len(sys.argv) != 2 or "blocked" in sys.argv[1]: sys.exit(1)\n'
            'shutil.move(sys.argv[1], os.path.join(os.environ["TEST_TRASH"],os.path.basename(sys.argv[1])))\n')
        gio = self.base / 'bin/gio'
        gio.write_text('#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n')
        gio.chmod(0o700)
        result = self.cleanup('--force', '--max-seconds', '2')
        self.assertIn('trashed=1', result)
        self.assertIn('failed=1', result)
        self.assertFalse(paths[0].exists())
        self.assertTrue(paths[1].exists())

    def test_fallback_rechecks_live_owner(self):
        self.cross_device_trash()
        path = self.create('revived')
        (path / MANIFEST).rename(self.base / 'live-owner.json')
        self.old(path)
        (self.base / 'bin/trash').write_text(
            '#!/usr/bin/env python3\nimport os,shutil,sys\n'
            'shutil.copy(os.environ["TEST_LIVE_OWNER"], os.path.join(sys.argv[1], ".aidevops-task-temp.json"))\n'
            'sys.exit(1)\n')
        self.env['TEST_LIVE_OWNER'] = str(self.base / 'live-owner.json')
        gio = self.base / 'bin/gio'
        gio.write_text('#!/usr/bin/env python3\nimport os\n'
                       'open(os.environ["TEST_GIO_CALLED"], "w").close()\n')
        gio.chmod(0o700)
        self.env['TEST_GIO_CALLED'] = str(self.base / 'gio-called')
        self.cleanup('--force', '--max-seconds', '2')
        self.assertTrue(path.exists())
        self.assertFalse((self.base / 'gio-called').exists())


unittest.main(verbosity=2)
PY
