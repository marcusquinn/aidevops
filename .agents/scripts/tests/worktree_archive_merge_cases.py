#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Merge corruption and source-loss cases for the existing lifecycle harness."""

import hashlib
import json
import os
from pathlib import Path
import shutil
from unittest.mock import patch


class MergeCases:
    def test_merge_untracked_deleted_path_and_hook_isolation(self):
        self.start_conflicted_merge()
        self.git(self.work, 'rm', 'mixed.txt')
        (self.work / 'mixed.txt').write_bytes(b'recreated untracked resolution\n')
        # Both template and configured hooks must stay inert in scratch Git
        # repositories, object import and index restoration, not just checkout.
        hooks = self.root / 'template/hooks'
        hooks.mkdir(parents=True)
        sentinel = self.root / 'hook-executed'
        for name in ('reference-transaction', 'post-index-change', 'post-checkout'):
            hook = hooks / name
            hook.write_text('#!/bin/sh\ntouch "' + str(sentinel) + '"\n')
            hook.chmod(0o755)
        self.env['GIT_TEMPLATE_DIR'] = str(hooks.parent)
        config = self.root / 'global-config'
        config.write_text('[core]\n\thooksPath = ' + str(hooks) + '\n')
        self.env['GIT_CONFIG_GLOBAL'] = str(config)
        archive = self.archive()
        self.helper('verify', archive)
        target = self.root / 'restored'
        self.helper('restore', archive, '--target', target, '--verification-copy')
        self.assertEqual((target / 'mixed.txt').read_bytes(), b'recreated untracked resolution\n')
        self.assertEqual(self.git(target, 'ls-files', '--resolve-undo', '-z'), self.git(self.work, 'ls-files', '--resolve-undo', '-z'))
        self.assertFalse(sentinel.exists())

    def test_merge_ordered_parents_without_auto_merge(self):
        parents = []
        for number in range(2):
            branch = 'side-' + str(number)
            self.git(self.repo, 'checkout', '-qB', branch, 'develop')
            (self.repo / branch).write_text(branch + '\n')
            self.git(self.repo, 'add', branch)
            self.git(self.repo, 'commit', '-qm', branch)
            parents.append(self.git(self.repo, 'rev-parse', 'HEAD').strip())
        head = self.git(self.work, 'rev-parse', 'HEAD').strip()
        self.git(self.work, 'merge', '--no-commit', '--no-ff', 'side-0', 'side-1')
        self.assertFalse(self.auto_merge_path().exists())
        archive = self.archive()
        target = self.root / 'octopus'
        shutil.rmtree(self.work)
        shutil.rmtree(self.repo)
        self.helper('restore', archive, '--target', target)
        self.assertEqual(self.git(target, 'rev-parse', 'ORIG_HEAD').strip(), head)
        self.env['GIT_EDITOR'] = 'true'
        self.git(target, 'merge', '--continue')
        self.assertEqual(self.git(target, 'show', '-s', '--format=%P').strip(), b' '.join([head] + parents))

    def test_merge_migration_retirement_requires_independent_restore(self):
        self.start_conflicted_merge()
        bucket = self.legacy_pulse_bucket()
        migration = json.loads(self.migrate_bucket(bucket).stdout)
        record = json.loads(Path(migration['receipt']).read_text())
        self.assertEqual(record['source']['snapshot']['schema'], 4)
        from worktree_recovery_migrate import verify_archive
        lock_path = Path(migration['receipt']).parent / 'lock'
        descriptor = os.open(lock_path, os.O_RDWR)
        self.addCleanup(os.close, descriptor)
        with patch.dict(os.environ, self.env, clear=True):
            verify_archive(record, descriptor)
        # A valid bundle alone cannot authorize retirement if actual restore
        # reconstruction is unavailable or fails its comparison.
        import worktree_recovery_migrate as migrate
        original = migrate.archive_command
        def fail_restore(lock, *arguments):
            if arguments[0] == 'restore':
                raise ValueError('injected merge reconstruction failure')
            return original(lock, *arguments)
        with patch.dict(os.environ, self.env, clear=True), patch.object(migrate, 'archive_command', side_effect=fail_restore):
            with self.assertRaisesRegex(ValueError, 'reconstruction failure'):
                verify_archive(record, descriptor)
        self.assertTrue(bucket.is_dir())
        self.assertFalse((Path(migration['receipt']).parent / 'retirement.json').exists())

    def test_merge_unsupported_and_corrupt_state_is_refused(self):
        self.start_conflicted_merge()
        admin = self.auto_merge_path().parent
        for name, content in (('CHERRY_PICK_HEAD', b'0' * 40), ('MERGE_MODE', b'unknown'),
                              ('MERGE_HEAD', b'ref: refs/heads/other\n'), ('COMMIT_EDITMSG', b'uncommitted draft')):
            path = admin / name
            original = path.read_bytes() if path.exists() else None
            path.write_bytes(content)
            result = self.helper('archive', self.work, '--repo', 'fixture/repo', '--issue', '99',
                                 '--reason', 'failed-worker', '--base-branch', 'develop',
                                 '--output-root', self.archives, check=False)
            self.assertNotEqual(result.returncode, 0, name)
            path.unlink()
            if original is not None:
                path.write_bytes(original)
        message = admin / 'MERGE_MSG'
        original = message.read_bytes()
        message.unlink()
        message.symlink_to(self.root / 'absent')
        self.assertNotEqual(self.helper('archive', self.work, '--repo', 'fixture/repo', '--issue', '99',
                                       '--reason', 'failed-worker', '--base-branch', 'develop',
                                       '--output-root', self.archives, check=False).returncode, 0)
        message.unlink()
        message.write_bytes(original)
        archive = self.archive()
        from worktree_archive_state import validate_merge
        state = json.loads((archive / 'merge-state-v1.json').read_text())
        state['index'][0][0] = b'../escape'.hex()
        with self.assertRaisesRegex(ValueError, 'unsafe_path'):
            validate_merge(state)
        # Even a rehashed artifact cannot change the captured operation digest.
        path = archive / 'merge-state-v1.json'
        path.write_text(json.dumps(state))
        manifest = json.loads((archive / 'manifest.json').read_text())
        for artifact in manifest['artifacts']:
            if artifact['name'] == path.name:
                artifact.update(size=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        self.update_manifest(archive, **manifest)
        self.assertNotEqual(self.helper('verify', archive, check=False).returncode, 0)
        self.assertTrue(self.work.exists())

    def test_interrupted_merge_independent_continuation(self):
        # Content, add/add, modify/delete, rename and binary conflicts, with a
        # staged resolution and staged deletion retained in resolve-undo.
        self.git(self.repo, 'checkout', '-qb', 'other')
        (self.repo / 'mixed.txt').write_bytes(b'other\n')
        (self.repo / 'added').write_bytes(b'other add\n')
        (self.repo / 'binary.bin').write_bytes(b'\0other\xff')
        (self.repo / 'staged-delete').write_bytes(b'other deletion conflict\n')
        (self.repo / 'old-name').rename(self.repo / 'renamed')
        self.git(self.repo, 'add', '-A')
        self.git(self.repo, 'commit', '-qm', 'theirs')
        (self.work / 'mixed.txt').write_bytes(b'ours\n')
        (self.work / 'added').write_bytes(b'our add\n')
        (self.work / 'binary.bin').write_bytes(b'\0ours\xfe')
        (self.work / 'old-name').write_bytes(b'our renamed content\n')
        self.git(self.work, 'rm', 'staged-delete')
        self.git(self.work, 'add', '-A')
        self.git(self.work, 'commit', '-qm', 'ours')
        self.assertNotEqual(self.run_command('git', '-C', self.work, 'merge', 'other', check=False).returncode, 0)
        (self.work / 'added').write_bytes(b'staged add resolution\n')
        self.git(self.work, 'add', 'added')
        self.git(self.work, 'rm', 'staged-delete')
        (self.work / 'mixed.txt').write_bytes(b'partial resolution\n')
        (self.work / 'run.sh').chmod(0o755)
        (self.work / 'ordinary-untracked').write_bytes(b'ordinary\0bytes')
        unusual = os.fsdecode(b'odd\tname\n\xff')
        (self.work / unusual).write_bytes(b'path-safe staged bytes\0')
        self.git(self.work, 'add', '--', unusual)
        baseline = {option: self.git(self.work, 'ls-files', option, '-z') for option in ('--stage', '--resolve-undo')}
        status = self.git(self.work, 'status', '--porcelain=v1', '-z')
        comparison = self.git(self.work, 'diff', '--binary', 'AUTO_MERGE')
        parent = self.git(self.work, 'rev-parse', 'HEAD').strip()
        other = self.git(self.work, 'rev-parse', 'MERGE_HEAD').strip()
        objects = self.repo / '.git/objects'
        base_before = sum(path.stat().st_size for path in objects.rglob('*') if path.is_file())
        archive = self.archive()
        base_after = sum(path.stat().st_size for path in objects.rglob('*') if path.is_file())
        self.assertEqual(base_before, base_after)
        self.helper('verify', archive)
        self.helper('source-matches', archive, self.work)
        manifest = json.loads((archive / 'manifest.json').read_text())
        self.assertEqual(manifest['source_fingerprint']['schema'], 4)
        self.assertTrue(manifest['self_contained'])
        self.assertFalse((archive / 'git-admin.json').exists())
        # Compute the expected result independently on the original merge.
        (self.work / 'binary.bin').write_bytes(b'\0resolved\xff')
        (self.work / 'mixed.txt').write_bytes(b'final resolution\n')
        self.git(self.work, 'add', '-A')
        expected = self.git(self.work, 'write-tree')
        shutil.rmtree(self.work)
        shutil.rmtree(self.repo)
        self.helper('verify', archive)
        target = self.root / 'isolated'
        self.helper('restore', archive, '--target', target)
        self.git(target, 'gc', '--prune=now')
        for option, value in baseline.items():
            self.assertEqual(self.git(target, 'ls-files', option, '-z'), value)
        self.assertEqual(self.git(target, 'status', '--porcelain=v1', '-z'), status)
        self.assertEqual(self.git(target, 'diff', '--binary', 'AUTO_MERGE'), comparison)
        from worktree_archive_snapshot import git_snapshot
        self.assertEqual(git_snapshot(target), manifest['source_fingerprint'])
        (target / 'binary.bin').write_bytes(b'\0resolved\xff')
        (target / 'mixed.txt').write_bytes(b'final resolution\n')
        self.git(target, 'add', '-A')
        self.env['GIT_EDITOR'] = 'true'
        self.git(target, 'merge', '--continue')
        self.assertEqual(self.git(target, 'rev-parse', 'HEAD^{tree}'), expected)
        self.assertEqual(self.git(target, 'show', '-s', '--format=%P').strip(), parent + b' ' + other)
        print('Interrupted merge storage:', json.dumps({'archive_bytes': sum(path.stat().st_size for path in archive.iterdir()),
                                                       'incremental_shared_base_bytes': base_after - base_before}))
