#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Isolated HOME/gopass checks for `aidevops secret rm` (GH#35850); no real credentials."""
import json
import os
import shutil
# Isolated runtime tests execute repository helpers with argv-only calls.
import subprocess  # nosec B404
import tempfile
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


if __name__ == '__main__':
    unittest.main()
