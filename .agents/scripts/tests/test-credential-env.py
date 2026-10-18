#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#34929 isolated HOME runtime acceptance; synthetic secrets only."""
import json
import os
import subprocess  # nosec B404
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import credential_dotenv
import credential_env


class EnvAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.config = self.home / '.config/aidevops'
        self.config.mkdir(parents=True)
        self.value = 'synthetic-34929-never-display'
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.write(self.bin / 'gopass', '''#!/usr/bin/env python3
import sys
if sys.argv[1] == 'ls': print('aidevops/SERVICE_TOKEN')
elif sys.argv[1] == 'show': print('synthetic-34929-never-display')
else: sys.exit(1)
''', 0o700)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])

    def write(self, path, text, mode=0o600):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(mode)
        return path

    def command(self, args, **kwargs):
        result = subprocess.run(args, env=self.env, capture_output=True, text=True,
                                timeout=60, **kwargs)  # nosec B603
        self.assertNotIn(self.value, result.stdout + result.stderr)
        return result

    def records(self, kind):
        result = self.command([sys.executable, str(SCRIPTS / 'credential_audit.py'), kind])
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_mcp_regular_symlink_missing_and_tenants(self):
        path = self.write(self.config / 'mcp-env.sh', f'export SERVICE_TOKEN="{self.value}"\ninvalid line\n', 0o644)
        records = self.records('mcp-env')
        self.assertTrue(any(r['category'] == 'legacy-mcp-env' and r['severity'] == 'medium' for r in records))
        self.assertTrue(any(r['category'] == 'insecure-perms' for r in records))
        self.assertTrue(any(r['line'] == 1 and r['name'] == 'SERVICE_TOKEN' and r['category'] == 'prunable' for r in records))
        self.assertTrue(any(r['category'] == 'unsupported-structure' and r['line'] == 2 for r in records))
        path.unlink()
        self.write(self.config / 'credentials.sh', '')
        path.symlink_to('credentials.sh')
        self.assertEqual(self.records('mcp-env'), [])
        tenant = self.write(self.config / 'tenants/demo/mcp-env.sh', f'export OTHER_KEY="{self.value}"\n')
        self.assertTrue(any(r['file'] == str(tenant) and r['name'] == 'OTHER_KEY' for r in self.records('mcp-env')))
        path.unlink()
        self.write(self.home / '.zshrc', '[[ -f ~/.config/aidevops/mcp-env.sh ]] && source credentials.sh\n')
        self.assertTrue(any(r['category'] == 'missing-mcp-env-link' and r['severity'] == 'low' for r in self.records('mcp-env')))

    def test_plist_literal_key_path_and_permissions(self):
        path = self.write(self.config / 'plist-env-overrides.json', json.dumps({
            'launchd': {'SERVICE_TOKEN': self.value + '$`', 'NORMAL_NAME': self.value, 'EMPTY_KEY': ''}}), 0o644)
        before = path.read_bytes()
        records = self.records('plist-env')
        literals = [r for r in records if r['category'] == 'plist-literal']
        self.assertEqual([r['key_path'] for r in literals], [['launchd', 'SERVICE_TOKEN']])
        self.assertTrue(any(r['category'] == 'insecure-perms' for r in records))
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_project_git_states_registry_sweep_and_no_values(self):
        repo = self.home / 'Git/fixture'
        repo.mkdir(parents=True)
        self.assertEqual(self.command(['git', 'init', str(repo)]).returncode, 0)
        tracked = self.write(repo / '.env', f'SERVICE_TOKEN={self.value}\n')
        self.command(['git', '-C', str(repo), 'add', '.env'])
        local = self.write(repo / '.env.local', f"LOCAL_KEY='{self.value}' # comment\n")
        ignored = self.write(repo / '.env.private', f'PUNCT_SECRET={self.value}! # comment\nREF_TOKEN=$HOME\nEMPTY_KEY=\n')
        self.write(repo / '.gitignore', '.env.private\n')
        self.write(repo / '.env.example', f'EXAMPLE_TOKEN={self.value}\n')
        external = self.home / 'elsewhere/repo'
        external.mkdir(parents=True)
        self.command(['git', 'init', str(external)])
        extra = self.write(external / '.env', f'EXTERNAL_KEY={self.value}\n')
        self.write(self.config / 'repos.json', json.dumps({'initialized_repos': [{'path': str(external)}]}))
        template = self.write(repo / '.env.local.template', 'TEMPLATE_TOKEN=placeholder\n')
        self.command(['git', '-C', str(repo), 'add', template.name])
        records = self.records('env-files')
        self.assertFalse(any(r['file'] == str(template) for r in records))
        self.assertTrue(any(r['file'] == str(tracked) and r['category'] == 'tracked-env' and r['severity'] == 'high' for r in records))
        self.assertTrue(any(r['file'] == str(local) and r['category'] == 'unignored-env' and r['severity'] == 'medium' for r in records))
        self.assertEqual({r['category'] for r in records if r['file'] == str(ignored)}, {'env-literal'})
        self.assertTrue(any(r['name'] == 'SERVICE_TOKEN' and r.get('in_gopass') for r in records))
        self.assertTrue(any(r['file'] == str(extra) for r in records))
        self.assertFalse(any(r['name'] in ('REF_TOKEN', 'EMPTY_KEY', 'EXAMPLE_TOKEN') for r in records))
        scan = self.command(['bash', str(SCRIPTS / 'secret-hygiene-helper.sh'), 'scan-secrets'])
        self.assertIn('[HIGH]', scan.stdout)
        self.assertIn('tracked-env', scan.stdout)
        self.assertIn('PUNCT_SECRET', scan.stdout)

    def test_safe_fix_requires_confirmation_and_preserves_regular_files(self):
        path = self.config / 'mcp-env.sh'
        self.write(self.config / 'credentials.sh', '')
        records = [{'file': str(path), 'category': 'missing-mcp-env-link'}]
        logged = []
        credential_env.fix_missing_links(records, lambda _category: False, lambda: logged.append(1))
        self.assertFalse(os.path.lexists(path))
        credential_env.fix_missing_links(records, lambda _category: True, lambda: logged.append(1))
        self.assertEqual(os.readlink(path), 'credentials.sh')
        self.assertEqual(logged, [1])
        path.unlink()
        self.write(path, self.value)
        credential_env.fix_missing_links(records, lambda _category: True, lambda: logged.append(1))
        self.assertEqual(path.read_text(), self.value)
        self.assertEqual(logged, [1])

    def test_dotenv_unquoted_spaces_are_literal(self):
        self.assertEqual(credential_dotenv.dotenv_literal('two words # comment'), 'two words')
        self.assertEqual(credential_dotenv.dotenv_literal('punctuation!@%'), 'punctuation!@%')
        self.assertIsNone(credential_dotenv.dotenv_literal('${REFERENCE}'))

    def test_depth_and_malformed_sources(self):
        self.write(self.home / 'Git/a/b/c/.env', f'DEEP_KEY={self.value}\n')
        self.assertEqual(self.records('env-files'), [])
        # Outside any work tree there is no Git exposure to classify; names are still listed.
        loose = self.write(self.home / 'Git/loose/.env', f'LOOSE_KEY={self.value}\n')
        self.assertEqual([(r['file'], r['category']) for r in self.records('env-files')],
                         [(str(loose), 'env-literal')])
        self.write(self.config / 'plist-env-overrides.json', '{invalid')
        self.assertTrue(any(r['category'] == 'unreadable-plist' for r in self.records('plist-env')))


if __name__ == '__main__':
    unittest.main()
