#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Isolated HOME/gopass checks for `aidevops secret rm` (GH#35850); no real credentials."""
import json
import os
import shutil
import signal
# Isolated runtime tests execute repository helpers with argv-only calls.
import subprocess  # nosec B404
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
if BASH is None:
    raise RuntimeError('These runtime checks require bash')

FAKE_GOPASS = '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
store = Path(os.environ['FIXTURE_STORE'])
args = sys.argv[1:]
if args[0] == 'ls':
    print('\\n'.join('aidevops/' + p.name for p in sorted(store.iterdir())))
elif args[0] == 'show':
    path = store / args[-1].split('/')[-1]
    if not path.exists(): sys.exit(1)
    sys.stdout.write(path.read_text())
elif args[0] == 'rm':
    targets = [a for a in args[1:] if not a.startswith('-')]
    if len(targets) != 1: sys.exit(1)
    path = store / targets[0].split('/')[-1]
    if not path.exists(): sys.exit(1)
    path.unlink()
else:
    sys.exit(1)
'''


class SecretRemovalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        bin_dir = self.home / 'bin'
        bin_dir.mkdir()
        self.store = self.home / 'store'
        self.store.mkdir()
        gopass = bin_dir / 'gopass'
        gopass.write_text(FAKE_GOPASS)
        gopass.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), FIXTURE_STORE=str(self.store),
                        PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
        for key in ('AIDEVOPS_HEADLESS', 'FULL_LOOP_HEADLESS', 'WORKER_ISSUE_NUMBER',
                    'AIDEVOPS_HEADLESS_SESSION', 'AIDEVOPS_CREDENTIAL_INVENTORY'):
            self.env.pop(key, None)
        self.creds = self.home / '.config/aidevops/credentials.sh'
        self.creds.parent.mkdir(parents=True)
        self.creds.write_text('export KEEP_TOKEN="fixture-keep-35850"\n'
                              'export PLAIN_ONE="fixture-one-35850"\n'
                              'export PLAIN_TWO="fixture-two-35850"\n')
        self.creds.chmod(0o600)
        (self.store / 'GP_ONE').write_text('fixture-gp-one-35850')
        (self.store / 'GP_TWO').write_text('fixture-gp-two-35850')

    def secret(self, *args):
        # B603: repository helper argv with an isolated HOME and synthetic backend.
        return subprocess.run([BASH, str(SCRIPTS / 'secret-helper.sh'), *args], env=self.env,  # nosec B603
                              capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)

    def check(self, name):
        return self.secret('check', name).returncode

    def test_two_gopass_names_removed_in_one_call(self):
        result = self.secret('rm', 'GP_ONE', 'GP_TWO', '--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.check('GP_ONE'), 0)
        self.assertNotEqual(self.check('GP_TWO'), 0)
        self.assertNotIn('fixture-gp', result.stdout + result.stderr)

    def test_plaintext_removed_and_other_lines_kept(self):
        result = self.secret('remove', 'PLAIN_ONE', 'PLAIN_TWO', '--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.creds.read_text(), 'export KEEP_TOKEN="fixture-keep-35850"\n')
        self.assertNotIn('fixture-', result.stdout + result.stderr)

    def test_unknown_name_fails_and_changes_nothing(self):
        before = self.creds.read_bytes()
        result = self.secret('rm', 'GP_ONE', 'NO_SUCH_NAME', '--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Secret not found: NO_SUCH_NAME', result.stderr + result.stdout)
        self.assertEqual(self.check('GP_ONE'), 0)
        self.assertEqual(self.creds.read_bytes(), before)

    def test_confirmation_required_without_yes(self):
        result = self.secret('rm', 'GP_ONE')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.check('GP_ONE'), 0)

    def test_registry_record_removed_with_yes(self):
        registry = self.home / '.config/aidevops/credential-inventory.json'
        recorded = self.secret('record', 'GP_ONE', '--provider', 'acme')
        self.assertEqual(recorded.returncode, 0, recorded.stderr)
        result = self.secret('rm', 'GP_ONE', '--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('registry', result.stdout + result.stderr)
        self.assertNotIn('GP_ONE', json.loads(registry.read_text())['credentials'])

    def stall_discovery(self):
        repo = self.home / 'repo'
        repo.mkdir()
        (self.creds.parent / 'repos.json').write_text(json.dumps({
            'initialized_repos': [{'path': str(repo), 'slug': 'fixture'}],
        }))
        self.git_pid_file = self.home / 'git.pid'
        self.env['FIXTURE_GIT_PID'] = str(self.git_pid_file)
        self.addCleanup(self.cleanup_stalled_git)
        git = self.home / 'bin/git'
        git.write_text('#!/usr/bin/env python3\nimport os, time\n'
                       'from pathlib import Path\n'
                       'Path(os.environ["FIXTURE_GIT_PID"]).write_text(str(os.getpid()))\n'
                       'time.sleep(60)\n')
        git.chmod(0o700)

    def stalled_git_running(self, pid):
        # kill(0) authoritatively reports a missing PID; ps only refines zombies.
        # A ps failure (e.g. BusyBox rejecting -p) is unknown state: treat as running.
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        ps = shutil.which('ps')
        if ps is None:
            return True
        result = subprocess.run([ps, '-o', 'stat=', '-p', str(pid)],  # nosec B603
                                capture_output=True, text=True, timeout=2)
        state = result.stdout.strip()
        if result.returncode != 0 and not state:
            # procps exits 1 for a missing PID with no stderr; any stderr is a ps error.
            return bool(result.stderr.strip())
        return bool(state) and not state.startswith('Z')

    def cleanup_stalled_git(self):
        if self.git_pid_file.exists():
            pid = int(self.git_pid_file.read_text())
            if self.stalled_git_running(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def assert_stalled_git_exited(self):
        self.assertTrue(self.git_pid_file.exists(), 'Fake git never started')
        pid = int(self.git_pid_file.read_text())
        deadline = time.monotonic() + 2
        while self.stalled_git_running(pid):
            if time.monotonic() >= deadline:
                self.fail('Fake git survived the dependency scan timeout')
            time.sleep(0.05)

    def test_dependents_discovery_has_whole_scan_deadline_and_clean_json(self):
        self.stall_discovery()
        start = time.monotonic()
        result = self.secret('dependents', 'GP_ONE', '--json')
        self.assert_stalled_git_exited()
        self.assertLess(time.monotonic() - start, 10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scanning dependents', result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report['complete'])
        self.assertEqual(report['skipped'][0]['reason'], 'whole scan timeout')

    def test_batch_removal_uses_one_scan_budget(self):
        self.stall_discovery()
        start = time.monotonic()
        result = self.secret('rm', 'GP_ONE', 'GP_TWO', '--yes')
        self.assert_stalled_git_exited()
        self.assertLess(time.monotonic() - start, 10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count('Scanning dependents'), 1)
        self.assertIn('scan incomplete', result.stderr)
        self.assertNotEqual(self.check('GP_ONE'), 0)
        self.assertNotEqual(self.check('GP_TWO'), 0)

    def test_skip_scan_preserves_registry_cleanup(self):
        self.stall_discovery()
        recorded = self.secret('record', 'GP_ONE', '--provider', 'acme')
        self.assertEqual(recorded.returncode, 0, recorded.stderr)
        start = time.monotonic()
        result = self.secret('rm', 'GP_ONE', '--yes', '--skip-dependents')
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Scanning dependents', result.stderr)
        self.assertIn('scan skipped', result.stderr)
        registry = self.creds.parent / 'credential-inventory.json'
        self.assertNotIn('GP_ONE', json.loads(registry.read_text())['credentials'])
        self.assertNotEqual(self.check('GP_ONE'), 0)

    def test_skip_scan_does_not_imply_confirmation(self):
        result = self.secret('rm', 'GP_ONE', '--skip-dependents')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Confirmation required', result.stderr)
        self.assertEqual(self.check('GP_ONE'), 0)

    def test_dependents_finds_literal_reference_without_values(self):
        config = self.creds.parent / 'reference.conf'
        config.write_text('GP_ONE=synthetic-private-content\n')
        result = self.secret('dependents', 'GP_ONE', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(any(hit['path'] == str(config) for hit in report['literal']))
        self.assertNotIn('synthetic-private-content', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
