#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Producer cases run by the existing archive lifecycle suite and its fixture."""

from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
from unittest.mock import patch

import worktree_recovery_producer as producer_engine


class ProducerCases:
    def producer(self, command, path, *arguments, check=True):
        script = Path(producer_engine.__file__)
        return self.run_command(sys.executable, script, command, path, *arguments, check=check)

    def test_producer_metadata_diagnostics_are_allowlisted(self):
        messages = (
            "ownership, ACLs or extended attributes require separate preservation",
            "special permissions or hard links require separate preservation",
        )
        for message in messages:
            error = subprocess.CalledProcessError(
                1, ["private-command"], output="private stdout",
                stderr="Traceback: private path and source text\nValueError: " + message + "\n")
            reason = producer_engine.failure_reason(error)
            self.assertTrue(reason.startswith("producer:unsupported-metadata;"))
            self.assertEqual(reason, producer_engine.failure_reason(ValueError(message)))
            self.assertNotIn("private", reason)
        for stderr in (None, "", "private failure", "ValueError: " + messages[0] + " private-path",
                       "ValueError: " + messages[0] + "\nother failure", messages[0].encode()):
            error = subprocess.CalledProcessError(1, ["private-command"], stderr=stderr)
            self.assertEqual(producer_engine.failure_reason(error), "producer:evidence-unavailable")
        timeout_reason = producer_engine.failure_reason(subprocess.TimeoutExpired("private", 1))
        self.assertTrue(timeout_reason.startswith("producer:git-timeout;"))
        self.assertNotIn("private", timeout_reason)

    def test_base_import_timeout_is_bounded_and_sanitized(self):
        import worktree_archive_snapshot as snapshot_engine
        self.assertEqual(snapshot_engine.base_import_timeout(), 300)
        for raw, expected in (("5", 60), ("99999", 1800), ("bad", 300), ("120", 120)):
            with patch.dict(os.environ, {"AIDEVOPS_WORKTREE_BASE_IMPORT_TIMEOUT": raw}):
                self.assertEqual(snapshot_engine.base_import_timeout(), expected)
        manifest = {"base_sha": "a" * 40, "source_git_common_dir": str(self.repo / ".git")}
        with patch.object(snapshot_engine, "git", side_effect=subprocess.TimeoutExpired("private", 1)):
            with self.assertRaises(ValueError) as caught:
                snapshot_engine.seed_base(self.work, manifest)
        self.assertTrue(str(caught.exception).startswith("producer:base-import-timeout;"))
        self.assertNotIn("private", str(caught.exception))
        target = self.root / 'timed-base'
        target.mkdir(mode=0o700)
        self.git(target, 'init', '-q')
        # One deadline covers all inspection/authorization/import/verification
        # subprocesses, rather than renewing a full budget for each command.
        with patch.dict(os.environ, self.env, clear=True), patch.object(snapshot_engine, 'time') as clock, \
                patch.object(snapshot_engine, 'git', wraps=snapshot_engine.git) as commands:
            clock.monotonic.side_effect = [0, 100, 200, 301]
            with self.assertRaisesRegex(ValueError, 'producer:base-import-timeout'):
                snapshot_engine.seed_base(target, manifest)
        self.assertEqual([call.kwargs['timeout'] for call in commands.call_args_list], [200, 100])

    def test_tracked_permissions_follow_git_model(self):
        self.env.pop("AIDEVOPS_WORKTREE_RECOVERY_POLICY", None)
        tracked = self.work / "mixed.txt"
        original = tracked.read_bytes()
        registration = self.git(self.repo, "worktree", "list", "--porcelain")
        for mode in (0o664, 0o775):
            with self.subTest(mode=oct(mode)):
                tracked.chmod(mode)
                archive = self.archive()
                self.helper("verify", archive)
                self.assertEqual(tracked.read_bytes(), original)
                self.assertEqual(stat.S_IMODE(tracked.stat().st_mode), mode)
                self.assertEqual(self.git(self.repo, "worktree", "list", "--porcelain"), registration)

    def test_base_import_is_exact_and_independent(self):
        import worktree_archive_snapshot as snapshot_engine
        base = self.git(self.repo, 'rev-parse', 'HEAD').decode().strip()
        expected = self.git(self.repo, 'rev-list', '--objects', '--no-object-names', base)
        (self.repo / 'future').write_bytes(b'unrelated future object\n')
        self.git(self.repo, 'add', 'future')
        self.git(self.repo, 'commit', '-qm', 'unrelated future')
        future = self.git(self.repo, 'rev-parse', 'HEAD').decode().strip()
        target = self.root / 'independent-base'
        target.mkdir()
        self.git(target, 'init', '-q')
        manifest = {'base_sha': base, 'source_git_common_dir': str(self.repo / '.git')}
        with patch.dict(os.environ, self.env, clear=True):
            snapshot_engine.seed_base(target, manifest)
        self.assertEqual(self.git(target, 'rev-list', '--objects', '--no-object-names', '--all'), expected)
        self.assertNotEqual(self.run_command('git', '-C', target, 'cat-file', '-e', future,
                                            check=False).returncode, 0)
        self.assertFalse((target / '.git/objects/info/alternates').exists())
        # Only the owned disposable source is hidden. Checkout/fsck must still
        # work with no source objects available, not just a mutable reference.
        (self.repo / '.git/objects').rename(self.repo / '.git/hidden-objects')
        self.git(target, 'checkout', '-q', '--detach', base)
        self.git(target, 'fsck', '--full')
        self.assertEqual((target / 'mixed.txt').read_bytes(), b'base\n')

    def test_base_import_diagnostics_are_allowlisted_through_nested_cli(self):
        from worktree_archive_git import base_import_failure
        for raw, detail in ((b'private pack-objects died: malloc failed', 'allocation-failed'),
                            ('private pack-objects died: No space left on device', 'storage-full'),
                            (b'private pack-objects died', 'unclassified'),
                            (None, 'unclassified')):
            error = subprocess.CalledProcessError(128, ['private'], stderr=raw)
            message = base_import_failure(error)
            self.assertIn('exit=128;', message)
            self.assertIn('/' + detail + ';', message)
            self.assertNotIn('private', message)
            for prefix in ('ValueError: ', 'archive-snapshot: ', ''):
                for encoded in (False, True):
                    stderr = 'private traceback\n' + prefix + message + '\n'
                    nested = subprocess.CalledProcessError(1, ['private'],
                                                          stderr=stderr.encode() if encoded else stderr)
                    self.assertEqual(producer_engine.failure_reason(nested), message)
            for suffix in (' private', '\nprivate failure'):
                nested = subprocess.CalledProcessError(1, ['private'], stderr=message + suffix)
                self.assertEqual(producer_engine.failure_reason(nested), 'producer:evidence-unavailable')

    def incomplete_promisor_fixture(self):
        # A historical blob absent at HEAD forces full-graph verification, not
        # merely a successful checkout. Everything lives in this disposable fixture.
        (self.repo / 'historical').write_bytes(b'promised historical payload\n')
        self.git(self.repo, 'add', 'historical')
        self.git(self.repo, 'commit', '-qm', 'historical payload')
        self.git(self.repo, 'rm', '-q', 'historical')
        self.git(self.repo, 'commit', '-qm', 'remove historical payload')
        base = self.git(self.repo, 'rev-parse', 'HEAD').decode().strip()
        expected = self.git(self.repo, 'rev-list', '--objects', '--no-object-names', base)
        self.git(self.work, 'reset', '--hard', base)
        origin = self.root / 'promisor-origin'
        self.run_command('git', 'clone', '-q', '--bare', '--no-hardlinks', self.repo, origin)
        self.git(origin, 'config', 'uploadpack.allowFilter', 'true')
        (self.repo / 'future').write_bytes(b'unrelated future payload\n')
        self.git(self.repo, 'add', 'future')
        self.git(self.repo, 'commit', '-qm', 'future payload')
        future = self.git(self.repo, 'rev-parse', 'HEAD').decode().strip()
        self.git(self.repo, 'push', '-q', str(origin), 'HEAD:refs/heads/future')
        self.git(self.repo, 'reset', '--hard', base)
        partial = self.root / 'incomplete-partial'
        self.run_command('git', 'clone', '-q', '--filter=blob:none', '--no-checkout',
                         origin.as_uri(), partial)
        self.git(partial, 'checkout', '-q', '--detach', base)
        # This is a genuine filtered clone, with current checkout blobs hydrated
        # but historical promised blobs still absent. Install its object store in
        # the fixture's source without invoking any production lifecycle helper.
        (self.repo / '.git/objects').rename(self.repo / '.git/saved-full-objects')
        shutil.copytree(partial / '.git/objects', self.repo / '.git/objects')
        self.git(self.repo, 'config', 'remote.origin.url', origin.as_uri())
        self.git(self.repo, 'config', 'remote.origin.promisor', 'true')
        self.git(self.repo, 'config', 'remote.origin.partialclonefilter', 'blob:none')
        self.env['GIT_NO_LAZY_FETCH'] = '1'
        missing = self.git(self.repo, 'rev-list', '--objects', '--no-object-names', '--missing=print', base)
        self.assertTrue(any(line.startswith(b'?') for line in missing.splitlines()))
        return origin, base, future, expected

    def test_missing_promisor_fails_closed_through_producer(self):
        from worktree_archive_git import MISSING_PROMISOR_BASE
        origin, base, _, _ = self.incomplete_promisor_fixture()
        result = self.producer('capture', self.work, self.archives, 'test.sh', 'promisor')
        archive = Path(result.stdout.decode().strip())
        managed, sealed = self.seal_promisor_source()
        manifest = (archive / 'manifest.json').read_bytes()
        source_files = {path.relative_to(self.repo / '.git'): path.read_bytes()
                        for path in (self.repo / '.git').rglob('*') if path.is_file()}
        journal = producer_engine.journal_for_archive(archive)
        failed = self.producer('verify', archive, check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(MISSING_PROMISOR_BASE.encode(), failed.stderr)
        self.assertNotIn(str(origin).encode(), failed.stderr)
        self.assertNotIn(base.encode(), failed.stderr)
        self.assertEqual((archive / 'manifest.json').read_bytes(), manifest)
        self.assertEqual({path.relative_to(self.repo / '.git'): path.read_bytes()
                          for path in (self.repo / '.git').rglob('*') if path.is_file()}, source_files)
        self.assertEqual(self.managed_record(managed), sealed)
        record = json.loads(journal.read_text())
        self.assertEqual(record['phase'], 'archived')
        self.assertEqual(record['source_removal_outcome'], 'pending')
        scratch = list(archive.parent.glob('.archive-verify-*'))
        self.assertEqual(len(scratch), 1)
        self.assertEqual(stat.S_IMODE(scratch[0].stat().st_mode), 0o700)
        # The existing producer records each attempted restoration, but cannot
        # advance its source/removal receipt or overwrite verification evidence.
        failed = self.producer('verify', archive, check=False)
        self.assertNotEqual(failed.returncode, 0)
        retried = json.loads(journal.read_text())
        for key in ('phase', 'source', 'source_removal_outcome', 'manifest_sha256'):
            self.assertEqual(retried[key], record[key])
        self.assertEqual(list(archive.parent.glob('.archive-verify-*')), scratch)
        self.assertEqual(self.managed_record(managed), sealed)

    def seal_promisor_source(self):
        managed = self.managed_fixture()
        with closing(sqlite3.connect(self.env['WORKTREE_REGISTRY_DB'])) as connection:
            record = managed.load(connection, str(self.work))
            managed.seal(record)
            managed.save(connection, record)
            connection.commit()
        sealed = self.managed_record(managed)
        self.assertEqual(sealed['state'], 'sealed')
        return managed, sealed

    def test_authorized_promisor_recovery_is_exact_and_independent(self):
        import worktree_archive_snapshot as snapshot_engine
        origin, base, future, expected = self.incomplete_promisor_fixture()
        managed, sealed = self.seal_promisor_source()
        target = self.root / 'recovered-base'
        target.mkdir(mode=0o700)
        self.git(target, 'init', '-q')
        common = self.repo / '.git'
        manifest = {'base_sha': base, 'source_git_common_dir': str(common)}
        before = {path.relative_to(common): path.read_bytes() for path in common.rglob('*') if path.is_file()}
        self.env.update(AIDEVOPS_WORKTREE_BASE_RECOVERY_SOURCE=origin.as_uri(),
                        AIDEVOPS_WORKTREE_BASE_RECOVERY_COMMON_DIR=str(common))
        with patch.dict(os.environ, self.env, clear=True):
            snapshot_engine.seed_base(target, manifest)
        self.assertEqual({path.relative_to(common): path.read_bytes() for path in common.rglob('*')
                          if path.is_file()}, before)
        self.assertEqual(self.managed_record(managed), sealed)
        self.assertEqual(self.git(target, 'rev-list', '--objects', '--no-object-names', '--all'), expected)
        self.assertFalse((target / '.git/objects/info/alternates').exists())
        self.assertNotEqual(self.run_command('git', '-C', target, 'cat-file', '-e', future,
                                            check=False).returncode, 0)
        (common / 'objects').rename(common / 'hidden-objects')
        origin.rename(self.root / 'hidden-promisor-origin')
        self.git(target, 'checkout', '-q', '--detach', base)
        self.git(target, 'fsck', '--full')
        self.assertEqual((target / 'mixed.txt').read_bytes(), b'base\n')

    def test_promisor_recovery_rejects_mismatched_authority_and_url_rewrites(self):
        import worktree_archive_snapshot as snapshot_engine
        from worktree_archive_git import MISSING_PROMISOR_BASE
        origin, base, _, _ = self.incomplete_promisor_fixture()
        common = self.repo / '.git'
        manifest = {'base_sha': base, 'source_git_common_dir': str(common),
                    'recovery_source': origin.as_uri()}  # Archive content is not authority.
        target = self.root / 'unauthorized-base'
        target.mkdir(mode=0o700)
        self.git(target, 'init', '-q')
        for source, approved_common in (('', str(common)), (origin.as_uri(), ''),
                                        (origin.as_uri(), str(self.root)),
                                        ((self.root / 'other').as_uri(), str(common))):
            with self.subTest(source=source, common=approved_common):
                environment = dict(self.env, AIDEVOPS_WORKTREE_BASE_RECOVERY_SOURCE=source,
                                   AIDEVOPS_WORKTREE_BASE_RECOVERY_COMMON_DIR=approved_common)
                with patch.dict(os.environ, environment, clear=True), \
                        patch.object(snapshot_engine, 'git', wraps=snapshot_engine.git) as commands:
                    with self.assertRaisesRegex(ValueError, 'producer:missing-promisor-object'):
                        snapshot_engine.seed_base(target, manifest)
                    self.assertFalse(any('fetch' in call.args for call in commands.call_args_list))
        self.git(target, 'config', f'url.{(self.root / "other").as_uri()}.insteadOf', origin.as_uri())
        environment = dict(self.env, AIDEVOPS_WORKTREE_BASE_RECOVERY_SOURCE=origin.as_uri(),
                           AIDEVOPS_WORKTREE_BASE_RECOVERY_COMMON_DIR=str(common))
        with patch.dict(os.environ, environment, clear=True):
            with self.assertRaises(ValueError) as caught:
                snapshot_engine.seed_base(target, manifest)
        self.assertEqual(str(caught.exception), MISSING_PROMISOR_BASE)
        # Invocation against either the source or its linked worktree is never
        # permission to seed a shared store, even with otherwise valid consent.
        with patch.dict(os.environ, environment, clear=True):
            for receiver in (self.repo, self.work):
                with self.assertRaisesRegex(ValueError, 'base_import_requires_independent_scratch'):
                    snapshot_engine.seed_base(receiver, manifest)

    def test_promisor_https_redirect_policy_overrides_url_specific_config(self):
        import worktree_archive_snapshot as snapshot_engine
        # No HTTP fixture or network: inspect the real fetch argv, then let Git's
        # config URL matcher prove the effective redirect policy for that argv.
        source = 'https://example.invalid/fixture/repo.git'
        common = self.repo / '.git'
        base = self.git(self.repo, 'rev-parse', 'HEAD').decode().strip()
        target = self.root / 'https-policy'
        target.mkdir(mode=0o700)
        self.git(target, 'init', '-q')
        self.git(common, 'config', 'remote.origin.url', source)
        self.git(target, 'config', f'http.{source}.followRedirects', 'true')
        real_git = snapshot_engine.git
        fetches = []

        def intercepted(root, *args, **kwargs):
            if root == common and 'rev-list' in args:
                return b'?0123456789012345678901234567890123456789\n'
            if 'fetch' in args:
                fetches.append(args)
                raise subprocess.CalledProcessError(128, ['git'], stderr=b'fixture stop before network')
            return real_git(root, *args, **kwargs)

        environment = dict(self.env, AIDEVOPS_WORKTREE_BASE_RECOVERY_SOURCE=source,
                           AIDEVOPS_WORKTREE_BASE_RECOVERY_COMMON_DIR=str(common))
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(snapshot_engine, 'git', side_effect=intercepted):
            with self.assertRaises(ValueError):
                snapshot_engine.seed_base(target, {'base_sha': base, 'source_git_common_dir': str(common)})
        self.assertEqual(len(fetches), 1)
        options = fetches[0][:fetches[0].index('fetch')]
        self.assertEqual(self.git(target, *options, 'config', '--get-urlmatch',
                                  'http.followRedirects', source).strip(), b'false')
        self.assertIn('protocol.allow=never', options)
        self.assertIn('protocol.https.allow=always', options)

    def test_promisor_authorization_rejects_unsafe_transport_and_credentials(self):
        from worktree_archive_git import authorized_base_source, git, MISSING_PROMISOR_BASE
        common = self.repo / '.git'
        for source in ('ext::private-command', 'ssh://example.invalid/private',
                       'https://user:private@example.invalid/repo', 'https://example.invalid/repo?private',
                       'https://example.invalid/repo#private', 'https://[invalid/private',
                       'https://example.invalid/private\n'):
            self.git(common, 'config', 'remote.origin.url', source)
            environment = dict(self.env, AIDEVOPS_WORKTREE_BASE_RECOVERY_SOURCE=source,
                               AIDEVOPS_WORKTREE_BASE_RECOVERY_COMMON_DIR=str(common))
            with patch.dict(os.environ, environment, clear=True):
                # seed_base also maps malformed URL parsing exceptions to the
                # same fixed diagnostic; direct validation must never fetch.
                with self.assertRaises(ValueError):
                    authorized_base_source(self.work, common, git)
        from worktree_archive_git import base_import_failure, nested_base_import_failure
        error = subprocess.CalledProcessError(128, ['private'],
                                             stderr=b'could not fetch private from promisor remote')
        self.assertEqual(base_import_failure(error), MISSING_PROMISOR_BASE)
        for prefix in ('ValueError: ', 'archive-snapshot: ', ''):
            self.assertEqual(nested_base_import_failure(prefix + MISSING_PROMISOR_BASE), MISSING_PROMISOR_BASE)
        self.assertIsNone(nested_base_import_failure(MISSING_PROMISOR_BASE + ' private'))

    def test_local_pack_failure_retains_source_archive_journal_and_scratch(self):
        result = self.producer('capture', self.work, self.archives, 'test.sh', 'pack-failure')
        archive = Path(result.stdout.decode().strip())
        journal = producer_engine.journal_for_archive(archive)
        manifest = (archive / 'manifest.json').read_bytes()
        before = self.snapshot(self.work)
        # Exercise the real nested producer -> archive Bash -> Python -> fetch
        # path. This disposable PATH shim fails only the local packing server.
        binary = self.root / 'policy bin'
        binary.mkdir()
        shim = binary / 'git'
        real_git = shutil.which('git')
        original_path = self.env['PATH']
        shim.write_text(f'#!{sys.executable}\nimport os, sys\n'
                        'if "upload-pack" in sys.argv:\n'
                        '    sys.stderr.write("private source: pack-objects died; malloc failed\\n")\n'
                        '    sys.exit(128)\n'
                        # Keep the real policy shim, but exclude this fixture's
                        # shim from its native-Git search to prevent recursion.
                        f'environment = dict(os.environ, PATH={original_path!r})\n'
                        # runtime-env can export this fixture as native Git;
                        # discard only that self-reference before delegating.
                        'for name in ("AIDEVOPS_REAL_GIT_BIN", "AIDEVOPS_REAL_GIT"):\n'
                        '    if environment.get(name) == os.path.abspath(__file__):\n'
                        '        environment.pop(name)\n'
                        f'os.execve({real_git!r}, [{real_git!r}, *sys.argv[1:]], '
                        'environment)\n')
        shim.chmod(0o700)
        self.env['PATH'] = str(binary) + os.pathsep + self.env['PATH']
        failed = self.producer('verify', archive, check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b'producer:base-import-failed; stage=base-import; exit=128;', failed.stderr)
        self.assertIn(b'stderr=pack-objects-died/allocation-failed;', failed.stderr)
        self.assertNotIn(b'private source', failed.stderr)
        self.assertEqual((archive / 'manifest.json').read_bytes(), manifest)
        self.assertEqual(self.snapshot(self.work), before)
        record = json.loads(journal.read_text())
        self.assertEqual(record['phase'], 'archived')
        self.assertEqual(record['source_removal_outcome'], 'pending')
        self.assertEqual(record['canonical_restore']['state'], 'restoring')
        self.assertTrue((journal.parent / record['canonical_restore']['slot']).is_dir())
        retained = list(archive.parent.glob('.archive-verify-*'))
        self.assertEqual(len(retained), 1)
        self.assertEqual(stat.S_IMODE(retained[0].stat().st_mode), 0o700)
        evidence = {path: path.read_bytes() for path in retained[0].rglob('*') if path.is_file()}
        for _attempt in range(2):
            retried = self.producer('verify', archive, check=False)
            self.assertNotEqual(retried.returncode, 0)
            self.assertIn(b'archive-verify:retained-scratch;', retried.stderr)
            self.assertEqual(list(archive.parent.glob('.archive-verify-*')), retained)
            self.assertEqual({path: path.read_bytes() for path in retained[0].rglob('*')
                              if path.is_file()}, evidence)
            self.assertEqual((archive / 'manifest.json').read_bytes(), manifest)
            self.assertEqual(self.snapshot(self.work), before)
            record = json.loads(journal.read_text())
            self.assertEqual(record['phase'], 'archived')
            self.assertEqual(record['source_removal_outcome'], 'pending')

    def test_verification_scratch_is_exclusive_and_archive_specific(self):
        import worktree_archive_objects as objects
        first, second = self.root / 'first-archive', self.root / 'second-archive'
        first.mkdir()
        second.mkdir()

        def interrupted(archive, scratch, manifest):
            (scratch / 'evidence').write_bytes(b'keep interrupted verification')
            raise KeyboardInterrupt()

        with patch.object(objects, 'verify_object_graph', side_effect=interrupted) as graph:
            with self.assertRaises(KeyboardInterrupt):
                objects.verify_in_scratch(first, {})
            retained = list(self.root.glob('.archive-verify-*'))
            with self.assertRaisesRegex(ValueError, 'archive-verify:retained-scratch'):
                objects.verify_in_scratch(first, {})
            graph.assert_called_once()
        with patch.object(objects, 'verify_object_graph') as graph:
            objects.verify_in_scratch(second, {})
            objects.verify_in_scratch(second, {})
            self.assertEqual(graph.call_count, 2)
        self.assertEqual(list(self.root.glob('.archive-verify-*')), retained)
        self.assertEqual((retained[0] / 'evidence').read_bytes(), b'keep interrupted verification')
        # An existing symlink is a refusal, not permission to follow or delete it.
        saved = retained[0].with_name('saved-verification-evidence')
        retained[0].rename(saved)
        retained[0].symlink_to(saved, target_is_directory=True)
        with patch.object(objects, 'verify_object_graph') as graph:
            with self.assertRaisesRegex(ValueError, 'archive-verify:retained-scratch'):
                objects.verify_in_scratch(first, {})
            graph.assert_not_called()
        self.assertTrue(retained[0].is_symlink())
        self.assertEqual((saved / 'evidence').read_bytes(), b'keep interrupted verification')

    def test_git_only_capture_contains_commits_and_two_patches_without_verification(self):
        self.env.pop("AIDEVOPS_WORKTREE_RECOVERY_POLICY", None)
        (self.work / "committed.txt").write_bytes(b"committed work\n")
        self.git(self.work, "add", "committed.txt")
        self.git(self.work, "commit", "-qm", "worker commit")
        head = self.git(self.work, "rev-parse", "HEAD").strip()
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        (self.work / "new-staged").write_bytes(b"new staged file\n")
        (self.work / "binary.bin").write_bytes(b"\0staged\xff")
        self.git(self.work, "add", "mixed.txt", "new-staged", "binary.bin")
        self.git(self.work, "rm", "staged-delete")
        self.git(self.work, "mv", "old-name", "new-name")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "binary.bin").write_bytes(b"\0unstaged\xfe")
        (self.work / "unstaged-delete").unlink()
        (self.work / "run.sh").chmod(0o755)
        (self.work / "untracked").write_bytes(b"unique recovery data\n")
        cache = self.work / "cache.ignored"
        cache.mkdir()
        self.git(cache, "init", "-q")
        (cache / "payload").write_bytes(b"not recovery data\n")
        self.git(self.work, "config", "diff.noprefix", "true")
        self.git(self.work, "config", "color.ui", "always")
        options = ("--binary", "--full-index", "--no-ext-diff", "--no-textconv",
                   "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short")
        staged = self.git(self.work, "diff", "--cached", *options)
        unstaged = self.git(self.work, "diff", *options)
        result = self.producer("capture", self.work, self.archives, "test.sh", "git-only")
        archive = Path(result.stdout.decode().strip())
        manifest = json.loads((archive / "manifest.json").read_text())
        self.assertEqual(manifest["capture_policy"], "git-only")
        self.assertEqual(manifest["head_sha"].encode(), head)
        self.assertEqual((archive / "staged.patch").read_bytes(), staged)
        self.assertEqual((archive / "diff.patch").read_bytes(), unstaged)
        self.assertEqual((archive / "untracked-files.txt").read_bytes(), b"untracked\n")
        self.assertTrue((archive / "untracked.tar.gz").exists())
        self.assertFalse((archive / "git-admin.json").exists())
        self.assertIn(head + b" HEAD", self.git(self.repo, "bundle", "list-heads", str(archive / "commits.bundle")))
        record = json.loads(producer_engine.journal_for_archive(archive).read_text())
        self.assertEqual(record["phase"], "archived")
        self.assertEqual(record["source_removal_outcome"], "pending")
        rows = [json.loads(line) for line in Path(self.env["AIDEVOPS_RECOVERY_TIMING_LOG"]).read_text().splitlines()]
        commands = {row["stage"] for row in rows if row["stage"].startswith("archive-cli.")}
        self.assertEqual(commands, {"archive-cli.archive"})
        self.assertTrue(self.work.is_dir())
        self.assert_git_only_roundtrip(archive, head, options, staged, unstaged)
        (self.work / "intent-only").write_bytes(b"not staged\n")
        self.git(self.work, "add", "-N", "intent-only")
        rejected = self.producer("capture", self.work, self.archives, "test.sh", "git-only", check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(b"intent-to-add", rejected.stderr)
        self.assertTrue(self.work.is_dir())

    def assert_git_only_roundtrip(self, archive, head, options, staged, unstaged):
        # This is an external regression test, never part of archive capture.
        expected_index = self.git(self.work, "ls-files", "--stage", "-z")
        expected_status = self.git(self.work, "status", "--porcelain=v1", "--untracked-files=no")
        home = self.root / "restore-home"
        targets = self.root / "restore-worktrees"
        home.mkdir()
        targets.mkdir()
        self.env.update(HOME=str(home), AIDEVOPS_WORKTREE_BASE_DIR=str(targets),
                        AIDEVOPS_REPOS_FILE=str(home / "repos.json"),
                        WORKTREE_REGISTRY_DIR=str(home / "registry"),
                        WORKTREE_REGISTRY_DB=str(home / "registry/registry.db"))
        # Only the disposable fixture is pruned: prove restore imports the saved
        # commit from its bundle instead of borrowing an already-present object.
        base = self.git(self.repo, "rev-parse", "develop").decode().strip()
        self.git(self.repo, "update-ref", "refs/heads/feature/fixture", base)
        self.git(self.repo, "reflog", "expire", "--expire=now", "--all")
        self.git(self.repo, "gc", "--prune=now")
        missing = self.run_command("git", "-C", self.repo, "cat-file", "-e", head.decode(), check=False)
        self.assertNotEqual(missing.returncode, 0)
        restored = targets / "repo-restored"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual(self.git(restored, "rev-parse", "HEAD").strip(), head)
        self.assertEqual(self.git(restored, "ls-files", "--stage", "-z"), expected_index)
        self.assertEqual(self.git(restored, "diff", "--cached", *options), staged)
        self.assertEqual(self.git(restored, "diff", *options), unstaged)
        self.assertEqual(self.git(restored, "status", "--porcelain=v1", "--untracked-files=no"), expected_status)
        for name in ("committed.txt", "mixed.txt", "binary.bin", "new-staged", "new-name", "run.sh"):
            self.assertEqual((restored / name).read_bytes(), (self.work / name).read_bytes())
        self.assertEqual((restored / "untracked").read_bytes(), b"unique recovery data\n")
        for name in ("staged-delete", "unstaged-delete", "old-name", "cache.ignored"):
            self.assertFalse((restored / name).exists())
        self.assertEqual(self.git(restored, "rev-parse", "--path-format=absolute", "--git-common-dir"),
                         self.git(self.repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))

    def test_manual_cli_removal_and_independent_restore(self):
        scripts = Path(producer_engine.__file__).parent
        home = self.root / "home"
        home.mkdir()
        self.env.update(HOME=str(home), AIDEVOPS_DOCKER_TEARDOWN="0",
                        AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(self.archives),
                        AIDEVOPS_REPOS_FILE=str(home / "repos.json"),
                        WORKTREE_REGISTRY_DIR=str(home / "registry"),
                        WORKTREE_REGISTRY_DB=str(home / "registry/registry.db"),
                        AIDEVOPS_FULL_LOOP_CLEANUP_DIR=str(home / "receipts"),
                        AIDEVOPS_CLEANUP_LOG=str(home / "cleanup.log"),
                        GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_COUNT="1",
                        GIT_CONFIG_KEY_0="diff.autoRefreshIndex", GIT_CONFIG_VALUE_0="false")
        self.run_command("bash", "-c", 'source "$1" && _init_registry_db',
                         "fixture-registry", scripts / "shared-worktree-registry.sh")
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "unique.ignored").write_bytes(b"unique ignored\n")
        (self.work / "untracked").write_bytes(b"unique untracked\n")
        before = self.snapshot(self.work)
        index = self.git(self.work, "ls-files", "--stage", "-z")
        source_bytes = producer_engine.allocated_bytes(self.work)
        result = self.run_command("bash", scripts / "worktree-helper.sh", "remove",
                                  self.work, "--force", cwd=self.repo, check=False)
        if result.returncode and b"cwd-visibility-degraded" in result.stderr:
            self.assertTrue(self.work.is_dir())
            self.assertEqual(before, self.snapshot(self.work))
            self.assertFalse(list(self.archives.rglob("manifest.json")))
            self.skipTest("host CWD visibility is incomplete; rerun in an isolated PID namespace")
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors="replace"))
        locations = [line.removeprefix("Recovery archive: ") for line in result.stdout.decode().splitlines()
                     if line.startswith("Recovery archive: ")]
        self.assertEqual(len(locations), 1, result.stdout.decode())
        archive = Path(locations[0])
        self.assertFalse(self.work.exists())
        self.assertNotIn(str(self.work).encode(), self.git(self.repo, "worktree", "list", "--porcelain"))
        journal = producer_engine.journal_for_archive(archive)
        record = json.loads(journal.read_text())
        self.assertEqual(record["phase"], "archived")
        self.assertEqual(record["source_removal_outcome"], "removed")
        self.assertTrue((archive / ".aidevops-archive-pin").is_file())
        self.assertFalse(list(self.archives.glob("aidevops-worktree-cleanup-*")))
        self.assertFalse(list(journal.parent.glob(".restore-*")))
        retry = self.run_command("bash", scripts / "worktree-helper.sh", "remove",
                                 self.work, "--force", cwd=self.repo, check=False)
        self.assertNotEqual(retry.returncode, 0)
        self.assertEqual(list(self.archives.rglob("manifest.json")), [archive / "manifest.json"])
        self.assertIn(str(archive).encode(), self.helper("list", "--output-root", self.archives).stdout)
        self.producer("verify", archive)
        restored = self.root / "independent-restore"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual(self.git(restored, "ls-files", "--stage", "-z"), index)
        self.assertEqual(before, self.snapshot(restored))
        self.assertFalse((restored / "unique.ignored").exists())
        self.assertFalse((restored / ".git/objects/info/alternates").exists())
        self.git(restored, "fsck", "--connectivity-only")
        print(json.dumps({"cli_acceptance": {
            "source_retired": True, "source_allocated_bytes": source_bytes,
            "archive_allocated_bytes": producer_engine.allocated_bytes(archive),
            "transaction_metadata_allocated_bytes": producer_engine.allocated_bytes(journal.parent),
            "installed_store_reclamation_claimed": False}}, sort_keys=True))

    def test_list_discovers_producers_without_scratch_or_legacy_entries(self):
        standalone = self.archive()
        result = self.producer("capture", self.work, self.archives, "test.sh", "list-fixture")
        archive = Path(result.stdout.decode().strip())
        manifest = (standalone / "manifest.json").read_bytes()
        for relative in (".producer-transactions/fixture/scratch/manifest.json",
                         "aidevops-worktree-cleanup-fixture/worktree/docs/manifest.json",
                         ".producer-archives/not-a-transaction/fixture__repo/1/stamp/manifest.json"):
            path = self.archives / relative
            path.parent.mkdir(parents=True)
            metadata = json.loads(manifest)
            if relative.startswith("aidevops-worktree-cleanup-"):
                metadata.update(repo="aidevops-worktree-cleanup-fixture", issue="worktree")
            path.write_text(json.dumps(metadata))
        malformed = self.archives / "fixture__repo/99/malformed/manifest.json"
        malformed.parent.mkdir(parents=True)
        malformed.write_text("[]")
        alias = self.archives / ".producer-archives" / ("a" * 64) / "fixture__repo"
        alias.parent.mkdir(parents=True)
        alias.symlink_to(standalone.parents[1], target_is_directory=True)
        rows = self.helper("list", "--output-root", self.archives).stdout.decode().splitlines()
        self.assertEqual({row.rsplit("\t", 1)[-1] for row in rows}, {str(standalone), str(archive)})
        self.assertEqual(len(rows), 2)
        filtered = self.helper("list", "--output-root", self.archives,
                               "--repo", "fixture/repo", "--issue", "1").stdout.decode().splitlines()
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0].rsplit("\t", 1)[-1], str(standalone))
        self.assertTrue((archive / ".aidevops-archive-pin").is_file())

    def test_producer_transaction_round_trip_and_retry(self):
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "unique.ignored").write_bytes(b"unique ignored\n")
        (self.work / "untracked").write_bytes(b"unique untracked\n")
        result = self.producer("capture", self.work, self.archives, "test.sh", "producer-fixture")
        archive = Path(result.stdout.decode().strip())
        self.assertTrue(self.work.is_dir())
        self.assertFalse((archive / ".git").exists())
        journals = list((self.archives / ".producer-transactions").glob("*/journal.json"))
        self.assertEqual(len(journals), 1)
        journal = journals[0]
        record = json.loads(journal.read_text())
        self.assertEqual(record["phase"], "archived")
        self.assertEqual(record["source_removal_outcome"], "pending")
        self.assertFalse(list(journal.parent.glob(".restore-*")))
        self.assertFalse(list(journal.parent.glob(".cleanup-*")))
        repeat = self.producer("capture", self.work, self.archives, "test.sh", "producer-fixture")
        self.assertEqual(result.stdout, repeat.stdout)
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)
        self.producer("source-matches", archive, self.work)
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        self.producer("removed", archive)
        self.assertEqual(json.loads(journal.read_text())["source_removal_outcome"], "removed")
        offline = self.root / "original-repository-unavailable"
        self.repo.rename(offline)
        try:
            self.assertNotEqual(self.producer("verify", archive, check=False).returncode, 0)
        finally:
            offline.rename(self.repo)
        self.producer("verify", archive)
        restored = self.root / "independent-restore"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual((restored / "mixed.txt").read_bytes(), b"unstaged\n")
        self.assertEqual(self.git(restored, "show", ":mixed.txt"), b"staged\n")
        self.assertFalse((restored / "unique.ignored").exists())
        self.assertEqual((restored / "untracked").read_bytes(), b"unique untracked\n")
        self.assertFalse((restored / ".git/objects/info/alternates").exists())

    def test_producer_transaction_rejects_drift_without_duplicate(self):
        result = self.producer("capture", self.work, self.archives, "test.sh", "drift-fixture")
        archive = Path(result.stdout.decode().strip())
        (self.work / "late.txt").write_bytes(b"late data\n")
        self.assertNotEqual(self.producer("source-matches", archive, self.work, check=False).returncode, 0)
        retry = self.producer("capture", self.work, self.archives, "test.sh", "drift-fixture", check=False)
        self.assertNotEqual(retry.returncode, 0)
        self.assertIn(b"source-drift", retry.stderr)
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)
        self.assertTrue((self.work / "late.txt").is_file())
        self.assertNotEqual(self.producer("removed", archive, check=False).returncode, 0)
        self.producer("verify", archive)
        manifest = archive / "manifest.json"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        self.assertNotEqual(self.producer("verify", archive, check=False).returncode, 0)
        self.assertTrue(self.work.is_dir())

    def test_producer_rejects_replaced_source_inode(self):
        self.assert_replaced_identity_rejected("path")

    def test_producer_rejects_replaced_admin_inode(self):
        self.assert_replaced_identity_rejected("admin")

    def assert_replaced_identity_rejected(self, field):
        result = self.producer("capture", self.work, self.archives, "test.sh", "identity-fixture")
        archive = Path(result.stdout.decode().strip())
        record = json.loads(producer_engine.journal_for_archive(archive).read_text())
        target = Path(record["source"]["identity"][field])
        original = target.with_name(target.name + "-original")
        target.rename(original)
        shutil.copytree(original, target, symlinks=True)
        result = self.producer("source-matches", archive, self.work, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"source-drift", result.stderr)
        self.producer("verify", archive)
        self.assertTrue(original.is_dir())
        self.assertTrue(target.is_dir())

    def test_producer_resumes_captured_archive_without_duplicate(self):
        with patch.dict(os.environ, self.env), patch.object(
                producer_engine, "allocated_bytes", side_effect=OSError("interrupted after capture")):
            with self.assertRaises(OSError):
                producer_engine.prepare(self.work, self.archives, "test.sh", "interruption-fixture")
        manifests = list(self.archives.rglob("manifest.json"))
        self.assertEqual(len(manifests), 1)
        archive = manifests[0].parent
        journal = producer_engine.journal_for_archive(archive)
        self.assertEqual(json.loads(journal.read_text())["phase"], "captured")
        self.assertNotEqual(self.producer("verify", archive, check=False).returncode, 0)
        result = self.producer("capture", self.work, self.archives, "test.sh", "interruption-fixture")
        self.assertEqual(Path(result.stdout.decode().strip()), archive)
        self.assertEqual(json.loads(journal.read_text())["phase"], "archived")
        self.assertEqual(list(self.archives.rglob("manifest.json")), manifests)
        self.assertTrue(self.work.is_dir())

    def test_producer_preserves_partial_capture_and_serializes_retry(self):
        with patch.dict(os.environ, self.env):
            current, directory, output = producer_engine.reservation(self.work, self.archives)
            with producer_engine.operation_lock(directory):
                producer_engine.reserve(current, directory, output, "test.sh", "partial-fixture")
                blocked = self.producer("capture", self.work, self.archives, "test.sh", "partial-fixture", check=False)
                self.assertNotEqual(blocked.returncode, 0)
        partial = output / "partial-artifact"
        partial.write_bytes(b"interrupted capture evidence")
        for _ in range(2):
            retry = self.producer("capture", self.work, self.archives, "test.sh", "partial-fixture", check=False)
            self.assertNotEqual(retry.returncode, 0)
            self.assertIn(b"capture-incomplete", retry.stderr)
        self.assertEqual(partial.read_bytes(), b"interrupted capture evidence")
        self.assertEqual(list(output.iterdir()), [partial])
        self.assertTrue(self.work.is_dir())

    def test_producer_refuses_unsafe_roots_and_source_aliases(self):
        for root in (self.work / "archives", self.repo / ".git/archives"):
            result = self.producer("capture", self.work, root, "test.sh", "unsafe-root", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"unsafe-storage-root", result.stderr)
            self.assertFalse(root.exists())
        alias = self.root / "source-alias"
        alias.symlink_to(self.work, target_is_directory=True)
        result = self.producer("capture", alias, self.archives, "test.sh", "alias", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.archives.exists())
