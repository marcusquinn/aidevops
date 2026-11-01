#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Administration validation cases using the archive lifecycle test suite."""

import json
from pathlib import Path
import re
import tempfile

from worktree_archive_administration import administration_files


class AdministrationCases:
    def test_git_only_rejects_unpreserved_opaque_records(self):
        from worktree_archive_fingerprint import git_snapshot
        from worktree_archive_index import git_index_state

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        (admin / 'aidevops').mkdir(mode=0o700)
        for merge in (False, True):
            if merge:
                self.start_conflicted_merge()
            archive = self.archive()
            for name in ('aidevops/js-admission.json', 'aidevops-profile-publication.json'):
                with self.subTest(merge=merge, name=name):
                    record = admin / name
                    record.write_bytes(b'opaque historical record\n')
                    # Policy-neutral index validation must still support preserve-v1.
                    metadata = git_index_state(self.work)
                    reason = f'git_admin:requires_preservation:{name}'
                    with self.assertRaisesRegex(ValueError, re.escape(reason)):
                        git_snapshot(self.work, metadata=metadata)
                    result = self.helper('archive', self.work, '--repo', 'fixture/repo',
                                         '--issue', '99', '--reason', 'failed-worker',
                                         '--base-branch', 'develop', '--output-root', self.archives,
                                         check=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(reason.encode(), result.stderr)
                    # A record added after capture must block source retirement too.
                    self.assertNotEqual(self.helper('source-matches', archive, self.work,
                                                    check=False).returncode, 0)
                    self.assertTrue(self.work.is_dir())
                    self.assertEqual(record.read_bytes(), b'opaque historical record\n')
                    record.unlink()

    def test_legacy_js_admission_round_trip_preserves_local_commits(self):
        from worktree_archive_administration import administration
        from worktree_archive_snapshot import capture_administration, restore_administration, snapshot

        for number in range(2):
            (self.work / 'mixed.txt').write_text(f'local commit {number}\n')
            self.git(self.work, 'commit', '-qam', f'local commit {number}')
        head = self.git(self.work, 'rev-parse', 'HEAD').decode().strip()
        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        record = admin / 'aidevops/js-admission.json'
        record.parent.mkdir(mode=0o700)
        content = json.dumps({
            'schema': 1, 'branch': 'feature/fixture', 'head': head,
            'policy': 'none', 'resume_condition': 'historical fixture only',
            'state': 'blocked', 'status': 'not-ready', 'tools': {'tsc': 'missing'},
        }).encode() + b'\n'
        record.write_bytes(content)
        record.chmod(0o600)
        before = snapshot(self.work, True, True)
        # Exercise the retained legacy metadata format, not obsolete CLI flags.
        archive = self.root / 'legacy-admission-archive'
        archive.mkdir()
        capture_administration(self.work, archive, True)
        stored = json.loads((archive / 'git-admin.json').read_text())
        self.assertEqual(bytes.fromhex(stored['files']['aidevops/js-admission.json']), content)
        self.assertEqual(record.read_bytes(), content)
        self.assertEqual(snapshot(self.work, True, True), before)
        target = self.root / 'legacy-admission-restore'
        self.run_command('git', 'clone', '-q', archive / 'commits.bundle', target)
        restore_administration(target, archive)
        restored_admin = Path(self.git(target, 'rev-parse', '--absolute-git-dir').decode().strip())
        self.assertEqual((restored_admin / 'aidevops/js-admission.json').read_bytes(), content)
        self.assertEqual((restored_admin / 'aidevops').stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.git(target, 'rev-parse', 'HEAD').decode().strip(), head)
        self.assertEqual(self.git(target, 'rev-list', '--count', 'HEAD').strip(), b'3')
        self.assertEqual(snapshot(target, True, True), before)
        # The record participates in source matching rather than being discarded.
        record.write_bytes(content + b' ')
        self.assertNotEqual(snapshot(self.work, True, True), before)
        self.assertNotEqual(administration(self.work), stored)

    def test_permission_pending_marker_is_not_restored(self):
        self.check_runtime_marker('aidevops-permission-pending')

    def test_generation_marker_is_not_restored(self):
        self.check_runtime_marker('aidevops-generation.json')

    def check_runtime_marker(self, name):
        from worktree_archive_administration import administration

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        marker = admin / name
        escaped_name = re.escape(name)
        marker.write_text('fixture permission request\n')
        self.assertNotIn(marker.name, administration(self.work)['files'])
        (self.work / 'mixed.txt').write_bytes(b'preserved working change\n')
        archive = self.archive()
        target = self.root / 'permission-marker-restore'
        self.helper('restore', archive, '--target', target)
        restored_admin = Path(self.git(target, 'rev-parse', '--absolute-git-dir').decode().strip())
        restored_marker = restored_admin / marker.name
        if name == 'aidevops-generation.json':
            self.assertNotEqual(restored_marker.read_text(), marker.read_text())
            self.assertIsInstance(json.loads(restored_marker.read_text()), dict)
        else:
            self.assertFalse(restored_marker.exists())
        self.assertEqual((target / 'mixed.txt').read_bytes(), b'preserved working change\n')
        self.assertEqual(marker.read_text(), 'fixture permission request\n')
        marker.unlink()
        marker.symlink_to(admin / 'HEAD')
        with self.assertRaisesRegex(ValueError, f'^git_admin:symlink:{escaped_name}$'):
            administration(self.work)
        marker.unlink()
        marker.mkdir()
        with self.assertRaisesRegex(ValueError, f'^git_admin:unknown_entry:{escaped_name}$'):
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
