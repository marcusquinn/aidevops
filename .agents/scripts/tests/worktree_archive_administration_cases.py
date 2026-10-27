#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Administration validation cases using the archive lifecycle test suite."""

import json
from pathlib import Path
import tempfile

from worktree_archive_administration import administration_files


class AdministrationCases:
    def test_permission_pending_marker_is_not_restored(self):
        from worktree_archive_administration import administration

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        marker = admin / 'aidevops-permission-pending'
        marker.write_text('fixture permission request\n')
        self.assertNotIn(marker.name, administration(self.work)['files'])
        (self.work / 'mixed.txt').write_bytes(b'preserved working change\n')
        archive = self.archive()
        target = self.root / 'permission-marker-restore'
        self.helper('restore', archive, '--target', target)
        restored_admin = Path(self.git(target, 'rev-parse', '--absolute-git-dir').decode().strip())
        self.assertFalse((restored_admin / marker.name).exists())
        self.assertEqual((target / 'mixed.txt').read_bytes(), b'preserved working change\n')
        self.assertEqual(marker.read_text(), 'fixture permission request\n')
        marker.unlink()
        marker.symlink_to(admin / 'HEAD')
        with self.assertRaisesRegex(ValueError, '^git_admin:symlink:aidevops-permission-pending$'):
            administration(self.work)
        marker.unlink()
        marker.mkdir()
        with self.assertRaisesRegex(ValueError, '^git_admin:unknown_entry:aidevops-permission-pending$'):
            administration(self.work)

    def test_git_administration_fetch_head_validation(self):
        from worktree_archive_administration import administration, fetch_head_roots, load_administration

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        self.assertEqual(fetch_head_roots(''), [])
        self.assertEqual(fetch_head_roots((b'a' * 64 + b'\t\tSHA256 fixture\n').hex()), ['a' * 64])
        payload = self.root / 'admin-payload'
        payload.mkdir()
        state = administration(self.work)
        for data in (b'bad line\n', b'0' * 40 + b'\t\tzero\n',
                     b'f' * 40 + b'\tunexpected\tflag\n', b'--option\t\tunsafe\n'):
            with self.subTest(data=data):
                (admin / 'FETCH_HEAD').write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'invalid_FETCH_HEAD'):
                    administration(self.work)
                state['files']['FETCH_HEAD'] = data.hex()
                (payload / 'git-admin.json').write_text(json.dumps(state))
                with self.assertRaisesRegex(ValueError, 'invalid_FETCH_HEAD'):
                    load_administration(payload)

    def test_git_administration_rejects_batch_command_injection(self):
        from worktree_archive_snapshot import administration, administration_roots

        state = administration(self.work)
        head = self.git(self.work, 'rev-parse', 'HEAD').strip()
        for suffix in (b'\nupdate refs/heads/injected ' + head,
                       b'\x00delete refs/heads/archive-head'):
            with self.subTest(suffix=suffix):
                state['files']['ORIG_HEAD'] = (head + suffix).hex()
                with self.assertRaisesRegex(ValueError, 'git_admin:invalid_object_id'):
                    administration_roots(self.work, state)

    def test_git_administration_rejects_unknown_operations_and_locks(self):
        import worktree_archive_snapshot as snapshots

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        for name in sorted(snapshots.OPERATIONS | {'index.lock', 'unknown-entry'}):
            with self.subTest(name=name):
                path = admin / name
                path.write_text('fixture')
                # Validate legacy administration without writing an obsolete format.
                with self.assertRaisesRegex(ValueError, 'git_admin:'):
                    snapshots.snapshot(self.work, True, True)
                self.assertTrue(path.exists())
                if name == 'index.lock':
                    default = self.helper('archive', self.work, '--repo', 'fixture/repo',
                                          '--issue', '2', '--reason', 'failed-worker',
                                          '--base-branch', 'develop', '--output-root', self.archives,
                                          check=False)
                    self.assertNotEqual(default.returncode, 0)
                    self.assertIn(b'git_admin:index_locked:index.lock', default.stderr)
                path.unlink()
        self.assertFalse(list(self.archives.rglob('manifest.json')))

    def test_legacy_branches_requires_empty_independent_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            admin = Path(temporary)
            branches = admin / "branches"
            branches.mkdir()
            self.assertEqual(administration_files(admin, admin, False), {})
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, True)
            child = branches / "origin"
            child.write_text("legacy remote\n")
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, False)
            child.unlink()
            child.mkdir()
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, False)
            child.rmdir()
            branches.rmdir()
            branches.write_text("not a directory\n")
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, False)
            branches.unlink()
            branches.symlink_to(admin, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "^git_admin:symlink:branches$"):
                administration_files(admin, admin, False)
