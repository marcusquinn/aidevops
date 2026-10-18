#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Isolated HOME/gopass runtime checks for GH#34921; no real credentials read."""
import importlib.util
import json
import os
import pty
import select
import shutil
# Isolated runtime tests execute repository helpers with argv-only calls.
import subprocess  # nosec B404
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('credential_literals', SCRIPTS / 'credential_literals.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
BASH = shutil.which('bash')
if BASH is None:
    raise RuntimeError('These runtime checks require bash')


class CredentialAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.store = self.home / 'store'
        self.store.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), FIXTURE_STORE=str(self.store),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        for key in ('AIDEVOPS_HEADLESS', 'FULL_LOOP_HEADLESS', 'WORKER_ISSUE_NUMBER',
                    'AIDEVOPS_HEADLESS_SESSION', 'AIDEVOPS_AUDIT_LOG_DIR', 'AIDEVOPS_LOG_DIR',
                    'AUDIT_LOG_DIR', 'AUDIT_LOG_FILE'):
            self.env.pop(key, None)
        self.write(self.bin / 'gopass', '''#!/usr/bin/env python3
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
elif args[0] == 'insert':
    path = store / args[-1].split('/')[-1]
    if path.exists(): sys.exit(1)
    path.write_text(sys.stdin.read())
else:
    sys.exit(1)
''', 0o700)
        self.creds = self.home / '.config/aidevops/credentials.sh'
        self.values = ['fixture-equal-34921', 'fixture-old-34921', 'fixture-new-34921',
                       'fixture-missing-34921', 'fixture-glued-34921', 'fixture-mcp-34921']

    def write(self, path, content, mode=0o600):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(mode)

    def cmd(self, script, *args):
        # B603: repository helper argv with an isolated HOME and synthetic backend.
        return subprocess.run([BASH, str(SCRIPTS / script), *args], env=self.env,  # nosec B603
                              capture_output=True, text=True, timeout=30)

    def records(self):
        result = self.cmd('secret-helper.sh', 'audit-credentials')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_values(result.stdout + result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def assert_no_values(self, text):
        for value in self.values:
            self.assertNotIn(value, text)

    def tenant_fixture(self):
        self.write(self.creds, 'AIDEVOPS_ACTIVE_TENANT="default"\nsource "ignored-loader"\n')
        tenant = self.creds.parent / 'tenants/default/credentials.sh'
        self.write(tenant, f'export GLUED_TOKEN="{self.values[4]}"export OTHER_TOKEN="bad"\n'
                   'export EXPAND_KEY="$HOME/not-a-value"\n'
                   'export EQUAL_KEY="fixture-equal-34921"\n'
                   f'export DRIFT_TOKEN="{self.values[1]}"\n'
                   f'export MISSING_SECRET="{self.values[3]}"\n', 0o644)
        self.write(self.store / 'EQUAL_KEY', self.values[0])
        self.write(self.store / 'DRIFT_TOKEN', self.values[2])
        self.write(tenant.parent / 'credentials.sh.bak-old', 'never print backup', 0o644)
        return tenant

    def test_tenant_scan_and_json_never_print_values(self):
        tenant = self.tenant_fixture()
        records = self.records()
        for name, category, line in [('GLUED_TOKEN', 'glued-exports', 1),
                                     ('EXPAND_KEY', 'shell-expansion', 2),
                                     ('EQUAL_KEY', 'prunable', 3),
                                     ('DRIFT_TOKEN', 'drift', 4),
                                     ('MISSING_SECRET', 'not-in-gopass', 5)]:
            self.assertTrue(any(r['name'] == name and r['category'] == category
                                and r['line'] == line and r['file'] == str(tenant) for r in records))
        self.assertTrue(any(r['category'] == 'leftover' and r['mode'] == '644' for r in records))
        self.assertTrue(any(r['category'] == 'insecure-perms' and r['file'] == str(tenant) for r in records))
        # B603: fixed repository CLI and literal arguments, no shell interpolation.
        result = subprocess.run([BASH, str(SCRIPTS.parents[1] / 'aidevops.sh'), 'security', 'scan'],  # nosec B603
                                env=self.env, capture_output=True, text=True, timeout=30)
        for category in ('glued-exports', 'shell-expansion', 'prunable', 'drift', 'not-in-gopass', 'leftover'):
            self.assertIn(category, result.stdout)
        self.assert_no_values(result.stdout + result.stderr)
        startup = self.cmd('secret-hygiene-helper.sh', 'startup-check')
        self.assertIn('credential/MCP finding(s)', startup.stdout)

    def test_import_lists_all_bad_lines_without_writes(self):
        tenant = self.tenant_fixture()
        tenant.chmod(0o600)
        before = tenant.read_bytes()
        result = self.cmd('secret-helper.sh', 'import-credentials')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Line 1: GLUED_TOKEN (glued-exports)', result.stderr)
        self.assertIn('Line 2: EXPAND_KEY (shell-expansion)', result.stderr)
        self.assert_no_values(result.stdout + result.stderr)
        self.assertEqual(tenant.read_bytes(), before)
        self.assertFalse((self.store / 'MISSING_SECRET').exists())

    def test_shared_parser_categories(self):
        _, errors = audit.parse('export INNER_KEY="a"b"\nexport CR_KEY="a"\r\nif true; then\n', 'fixture')
        self.assertEqual([r['category'] for r in errors], ['inner-quote', 'crlf', 'unsupported-structure'])
        self.assertEqual(audit.literal('"a\\\\b\\\"c"'), 'a\\b"c')

    def test_unicode_separator_cannot_split_shell_assignments(self):
        for separator in ('\u2028', '\v', '\f', '\x85'):
            original = f'export EQUAL_KEY="a"{separator}export OTHER_KEY="b"\n'
            self.write(self.creds, original)
            result = self.cmd('secret-helper.sh', 'prune-plaintext')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.creds.read_text(), original)
            self.assertEqual(len(audit.physical_lines(original)), 1)
            assignments, errors = audit.parse('# comment' + separator + 'export OTHER_KEY="b"\n', 'fixture')
            self.assertEqual((assignments, errors), ([], []))

    def test_mcp_both_schemas_and_environment_keys(self):
        # These are configuration references, not embedded credential values.
        env_reference = '{env:FIXTURE_KEY}'
        file_reference = '{file:fixture}'
        for filename, key in [('.config/opencode/opencode.json', 'mcp'), ('.claude.json', 'mcpServers')]:
            path = self.home / filename
            self.write(path, json.dumps({key: {'fixture': {'env': {'SERVICE_API_KEY': self.values[-1],
                        'REF_TOKEN': env_reference, 'FILE_SECRET': file_reference, 'EMPTY_KEY': ''},
                        'environment': {'OTHER_TOKEN': self.values[-1]}}}}))
        result = self.cmd('secret-hygiene-helper.sh', 'audit-mcp')
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(records), 4)
        self.assertEqual({r['name'] for r in records}, {'SERVICE_API_KEY', 'OTHER_TOKEN'})
        scan = self.cmd('secret-hygiene-helper.sh', 'scan')
        self.assertIn('mcp-literal', scan.stdout)
        self.assert_no_values(result.stdout + scan.stdout + scan.stderr)

    def test_registry_failures_propagate(self):
        script = '''source "$1" help >/dev/null
rt_detect_configured() { printf '%s\\n' fixture; return 0; }
rt_config_path() { return 1; }
audit_mcp_configs
'''
        # B603: the shell program above is a fixed test fixture, not external input.
        result = subprocess.run([BASH, '-c', script, 'fixture', str(SCRIPTS / 'secret-hygiene-helper.sh')],  # nosec B603
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_fix_refuses_without_tty(self):
        result = self.cmd('security-fix-helper.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('interactive terminal', result.stderr)
        # B603: fixed repository CLI and literal arguments, isolated test environment.
        cli = subprocess.run([BASH, str(SCRIPTS.parents[1] / 'aidevops.sh'), 'security', 'fix'],  # nosec B603
                             env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(cli.returncode, 0)
        self.assertIn('interactive terminal', cli.stderr)

    def interactive(self, answers, headless=False):
        master, slave = pty.openpty()
        env = dict(self.env)
        if headless:
            env['AIDEVOPS_HEADLESS'] = 'true'
        # B603: fixed repository helper under a pseudo-terminal, no external command.
        child = subprocess.Popen([BASH, str(SCRIPTS / 'security-fix-helper.sh')],  # nosec B603
                                 env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = b''
        deadline = time.monotonic() + 30
        try:
            os.write(master, answers.encode())
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        block = os.read(master, 65536)
                    except OSError:
                        break
                    if not block:
                        break
                    output += block
                elif child.poll() is not None:
                    break
            child.wait(timeout=2)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(master)
        self.assert_no_values(output.decode())
        return child.returncode, output.decode()

    def fix_fixture(self):
        self.write(self.creds, 'export EQUAL_KEY="fixture-equal-34921"\n'
                   f'export DRIFT_TOKEN="{self.values[1]}"\n'
                   f'export MISSING_SECRET="{self.values[3]}"\n', 0o644)
        self.write(self.store / 'EQUAL_KEY', self.values[0])
        self.write(self.store / 'DRIFT_TOKEN', self.values[2])
        backup = self.creds.parent / 'credentials.sh.bak-old'
        self.write(backup, 'leftover')
        self.write(self.bin / 'trash', '#!/bin/sh\nmv "$1" "$HOME/trashed-backup"\n', 0o700)
        return backup

    def test_interactive_fix_declined_categories_preserved(self):
        backup = self.fix_fixture()
        rc, output = self.interactive('n\nn\n')
        self.assertEqual(rc, 0, output)
        self.assertEqual(self.creds.stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.store / 'MISSING_SECRET').exists())
        self.assertIn('EQUAL_KEY', self.creds.read_text())
        self.assertTrue(backup.exists())

    def test_interactive_fix_confirmed_prunes_and_trashes(self):
        backup = self.fix_fixture()
        rc, output = self.interactive('y\ny\n')
        self.assertEqual(rc, 0, output)
        content = self.creds.read_text()
        self.assertNotIn('EQUAL_KEY', content)
        self.assertIn('DRIFT_TOKEN', content)
        self.assertFalse(backup.exists())
        self.assertTrue((self.home / 'trashed-backup').exists())
        logs = (self.home / '.aidevops/.agent-workspace/observability/audit.jsonl').read_text()
        self.assert_no_values(logs)
        self.assertTrue(any('prune-plaintext' in line and 'MISSING_SECRET' in line for line in logs.splitlines()))

    def test_interactive_fix_keeps_unparseable_file(self):
        tenant = self.tenant_fixture()
        before = tenant.read_bytes()
        rc, output = self.interactive('n\n')
        self.assertEqual(rc, 0, output)
        self.assertEqual(tenant.read_bytes(), before)
        self.assertFalse((self.store / 'MISSING_SECRET').exists())

    def test_outscraper_migration_requires_confirmation_and_matching_custody(self):
        config = self.home / '.config/opencode/opencode.json'
        self.write(config, json.dumps({'mcp': {'outscraper': {'command': ['outscraper-mcp-server'],
                    'env': {'OUTSCRAPER_API_KEY': self.values[-1], 'UNRELATED': 'keep'},
                    'environment': {'OUTSCRAPER_API_KEY': self.values[-1]}}}}))
        before = config.read_bytes()
        rc, output = self.interactive('n\n')
        self.assertEqual(rc, 0, output)
        self.assertEqual(config.read_bytes(), before)
        # A confirmed migration without verified backend custody still retains the literal.
        rc, output = self.interactive('y\ny\n')
        self.assertEqual(rc, 0, output)
        self.assertEqual(config.read_bytes(), before)
        self.write(self.store / 'OUTSCRAPER_API_KEY', self.values[-1])
        rc, output = self.interactive('y\ny\n')
        self.assertEqual(rc, 0, output)
        entry = json.loads(config.read_text())['mcp']['outscraper']
        self.assertEqual(entry['env'], {'UNRELATED': 'keep'})
        self.assertNotIn('environment', entry)
        self.assertIn('outscraper_load_credentials', entry['command'][2])
        logs = self.home / '.aidevops/.agent-workspace/observability/audit.jsonl'
        self.assertTrue(logs.exists())
        self.assert_no_values(logs.read_text())
        self.assertIn('mcp-migrated', logs.read_text())

    def test_other_tenants_and_symlinks(self):
        self.tenant_fixture()
        other = self.creds.parent / 'tenants/other/credentials.sh'
        self.write(other, f'export OTHER_SECRET="{self.values[3]}"\n')
        records = self.records()
        self.assertTrue(any(r['name'] == 'OTHER_SECRET' and not r['active'] for r in records))
        other.unlink()
        other.symlink_to(self.store / 'EQUAL_KEY')
        records = self.records()
        self.assertTrue(any(r['file'] == str(other) and r['category'] == 'unreadable-source' for r in records))
        rc, output = self.interactive('y\n')
        self.assertNotEqual(rc, 0, output)
        self.assertTrue(other.is_symlink())

    def test_headless_tty_still_refused(self):
        self.fix_fixture()
        before = self.creds.read_bytes()
        rc, output = self.interactive('', headless=True)
        self.assertNotEqual(rc, 0)
        self.assertIn('headless', output)
        self.assertEqual(self.creds.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
