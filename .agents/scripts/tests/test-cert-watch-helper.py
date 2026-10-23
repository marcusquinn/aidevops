#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Execute the real helper in isolated HOME with local network/GitHub fixtures."""
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
if BASH is None:
    raise RuntimeError('Bash is required for helper execution tests')
FIXTURE = r'''
import json
import os
from pathlib import Path
import sys
root = Path(os.environ['HOME']) / 'fixtures'
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
def read(name, default):
    path = root / name
    return json.loads(path.read_text()) if path.exists() else default
def save(name, value):
    (root / name).write_text(json.dumps(value))
if tool == 'curl':
    calls = read('curl-calls.json', [])
    calls.append(args)
    save('curl-calls.json', calls)
    if (root / 'curl-fail').exists():
        sys.exit(22)
    print((root / 'ct.json').read_text())
elif tool == 'dig':
    name = args[-1]
    calls = read('dns-calls.json', [])
    calls.append(name)
    save('dns-calls.json', calls)
    records = read('dns.json', {}).get(name, [])
    if records is None:
        print(';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1')
    else:
        print(';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1')
        for flags, tag, value in records:
            print(f'{name}. 300 IN CAA {flags} {tag} {json.dumps(value)}')
elif tool == 'gh':
    if args[:2] == ['repo', 'view']:
        visibility = read('visibility.json', {}).get(args[2], 'PUBLIC')
        if visibility == 'FAIL':
            sys.exit(1)
        print(visibility if '--jq' in args else json.dumps({'visibility': visibility}))
    elif args[0] == 'api':
        if (root / 'dedup-fail').exists():
            sys.exit(1)
        print(json.dumps([read('issues.json', [])]))
    elif args[:2] == ['label', 'create']:
        writes = read('writes.json', [])
        writes.append(args)
        save('writes.json', writes)
    elif args[:2] == ['issue', 'create']:
        writes = read('writes.json', [])
        writes.append(args)
        save('writes.json', writes)
        body = Path(args[args.index('--body-file') + 1]).read_text()
        issues = read('issues.json', [])
        issues.append({'body': body})
        save('issues.json', issues)
    else:
        sys.exit('Unexpected gh invocation: ' + repr(args))
else:
    sys.exit('Unexpected tool')
'''


class CertWatchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cert-watch-test-', dir=os.environ.get('AIDEVOPS_TEMP_DIR'))
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.config_dir = self.home / '.config/aidevops'
        self.config_dir.mkdir(parents=True)
        self.fixture_dir = self.home / 'fixtures'
        self.fixture_dir.mkdir()
        scripts = self.home / 'agents/scripts'
        scripts.mkdir(parents=True)
        configs = scripts.parent / 'configs'
        configs.mkdir()
        self.helper = scripts / 'cert-watch-helper.sh'
        shutil.copy2(SOURCE / self.helper.name, self.helper)
        shutil.copy2(SOURCE.parent / 'configs/cert-watch-distrusted-issuers.conf', configs)
        # Source fixtures expose only the managed creation contract. Production
        # privacy checks and all engine/control flow are executed unchanged.
        (scripts / 'shared-constants.sh').write_text('# fixture constants\n')
        (scripts / 'shared-gh-wrappers.sh').write_text('gh_create_issue() { gh issue create "$@"; return $?; }\n')
        commands = self.home / 'bin'
        commands.mkdir()
        for tool in ('curl', 'dig', 'gh'):
            path = commands / tool
            path.write_text('#!' + sys.executable + '\n' + FIXTURE)
            path.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(commands) + ':' + os.environ['PATH'])
        self.config = {'extra_domains': ['example.com'], 'fallback_repo': 'owner/private'}
        self.write_config()
        self.write_fixture('ct.json', [])
        self.write_fixture('dns.json', {})
        self.write_fixture('visibility.json', {'owner/private': 'PRIVATE'})
        self.state = self.home / '.aidevops/.agent-workspace/work/cert-watch/example.com.json'

    def write_fixture(self, name, value):
        (self.fixture_dir / name).write_text(json.dumps(value))

    def write_config(self):
        self.private_json('cert-watch.json', self.config)

    def private_json(self, name, value):
        path = self.config_dir / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def run_helper(self, *args, success=True):
        result = subprocess.run([BASH, str(self.helper), *args, '--format', 'json'],  # nosec B603 -- resolved Bash, repository helper and fixture-owned argv
                                env=self.env, capture_output=True, text=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def cert(self, ident=1, issuer="Let's Encrypt", sans='example.com'):
        now = dt.datetime.now(dt.timezone.utc)
        return {'id': ident, 'issuer_name': f'C=US, O={issuer}, CN=Intermediate',
                'not_before': (now - dt.timedelta(days=10)).isoformat(),
                'not_after': (now + dt.timedelta(days=80)).isoformat(), 'name_value': sans}

    def test_inventory_sources_and_registrable_suffixes(self):
        psl = self.home / 'public-suffix.dat'
        psl.write_text('com\nuk\nco.uk\nck\n*.ck\n!www.ck\n')
        self.config.update(public_suffix_file=str(psl), ignore=['retired.example.com'])
        self.write_config()
        self.private_json('site-inventory.json', {'sites': {'site': {
            'canonical_hostname': 'WWW.Example.COM',
            'aliases': ['mail.example.com', 'retired.example.com', 'www.example.co.uk'],
            'knowledge_repo': 'owner/site'}}})
        self.private_json('repos.json', {'initialized_repos': [{'slug': 'owner/repo.com'}]})
        fleet = self.home / '.aidevops/.agent-workspace/work/hostinger-fleet'
        fleet.mkdir(parents=True)
        (fleet / 'inventory.json').write_text(json.dumps({'sites': [{'domain': 'fleet.com'}]}))
        rows = self.run_helper('domains')
        self.assertEqual([r['apex'] for r in rows], ['example.co.uk', 'example.com', 'fleet.com', 'repo.com'])
        row = next(r for r in rows if r['apex'] == 'example.com')
        self.assertIn('www.example.com', row['hostnames'])
        self.assertNotIn('retired.example.com', row['hostnames'])

    def test_baseline_and_unknown_preserve_state(self):
        self.write_fixture('ct.json', [self.cert()])
        self.assertEqual(self.run_helper('ct'), [])
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        before = self.state.read_bytes()
        for content in ('not JSON', '{}', '[{"id": 1}]'):
            (self.fixture_dir / 'ct.json').write_text(content)
            self.assertEqual(self.run_helper('ct')[0]['kind'], 'ct-unknown')
            self.assertEqual(self.state.read_bytes(), before)
        (self.fixture_dir / 'curl-fail').touch()
        self.assertEqual(self.run_helper('ct')[0]['kind'], 'ct-unknown')
        self.assertEqual(self.state.read_bytes(), before)

    def test_new_certificate_and_wildcard_coverage(self):
        self.write_fixture('ct.json', [self.cert(sans='*.example.com')])
        self.run_helper('ct')
        self.write_fixture('ct.json', [self.cert(2, 'eMudhra Limited', 'www.example.com\ndeep.www.example.com')])
        findings = self.run_helper('ct')
        self.assertEqual({f['kind'] for f in findings},
                         {'ct-unexpected-issuer', 'ct-distrusted-issuer', 'ct-unknown-hostname'})
        san = next(f for f in findings if f['kind'] == 'ct-unknown-hostname')
        self.assertEqual(san['reason'], 'Unrecognised SANs: deep.www.example.com')
        self.assertFalse((self.fixture_dir / 'writes.json').exists())

    def test_private_fallback_and_repeat_dedup(self):
        self.private_json('hosting-fleet.json', {'site_repos': {'example.com': 'owner/public'}})
        self.run_helper('run')
        self.assertFalse((self.fixture_dir / 'writes.json').exists())
        first = self.run_helper('run', '--apply')
        self.assertEqual(len(first), 1)
        writes = json.loads((self.fixture_dir / 'writes.json').read_text())
        for args in writes:
            self.assertEqual(args[args.index('--repo') + 1], 'owner/private')
            self.assertNotIn('auto-dispatch', args)
        issues = json.loads((self.fixture_dir / 'issues.json').read_text())
        self.assertEqual(len(issues), 1)
        self.assertIn('aidevops:generator=cert-watch', issues[0]['body'])
        self.run_helper('run', '--apply')
        self.assertEqual(json.loads((self.fixture_dir / 'writes.json').read_text()), writes)

    def test_no_public_or_unverified_writes(self):
        for visibility in ('PUBLIC', 'INTERNAL', 'FAIL'):
            self.write_fixture('visibility.json', {'owner/private': visibility})
            self.run_helper('run', '--apply')
            self.assertFalse((self.fixture_dir / 'writes.json').exists())
        self.config['fallback_repo'] = 'marcusquinn/aidevops'
        self.write_config()
        self.write_fixture('visibility.json', {'marcusquinn/aidevops': 'PRIVATE'})
        self.run_helper('run', '--apply')
        self.assertFalse((self.fixture_dir / 'writes.json').exists())

    def test_failed_dedup_does_not_write(self):
        (self.fixture_dir / 'dedup-fail').touch()
        self.run_helper('run', '--apply', success=False)
        self.assertFalse((self.fixture_dir / 'writes.json').exists())

    def test_caa_inheritance_and_issuewild(self):
        self.private_json('site-inventory.json', {'sites': {'site': {
            'canonical_hostname': 'www.example.com', 'aliases': []}}})
        self.write_fixture('ct.json', [self.cert(sans='www.example.com\n*.example.com')])
        self.run_helper('ct')
        self.write_fixture('dns.json', {'example.com': [[0, 'issue', 'letsencrypt.org']]})
        self.assertEqual(self.run_helper('caa'), [])
        calls = json.loads((self.fixture_dir / 'dns-calls.json').read_text())
        self.assertIn('www.example.com', calls)
        self.write_fixture('dns.json', {'example.com': [[0, 'issue', 'letsencrypt.org'], [0, 'issuewild', ';']]})
        findings = self.run_helper('caa')
        self.assertTrue(any(f['kind'] == 'caa-blocks-active-issuer' for f in findings))
        self.write_fixture('dns.json', {'example.com': None, 'www.example.com': None})
        self.assertEqual({f['kind'] for f in self.run_helper('caa')}, {'caa-unknown'})

    def test_dry_ct_findings_survive_until_filed(self):
        self.run_helper('ct')
        self.write_fixture('ct.json', [self.cert(2, 'eMudhra Limited')])
        self.assertTrue(self.run_helper('ct'))
        self.run_helper('run', '--apply')
        self.assertEqual(json.loads(self.state.read_text())['pending'], [])
        before = json.loads((self.fixture_dir / 'issues.json').read_text())
        self.run_helper('run', '--apply')
        self.assertEqual(json.loads((self.fixture_dir / 'issues.json').read_text()), before)

    def test_private_config_permissions(self):
        (self.config_dir / 'cert-watch.json').chmod(0o644)
        self.run_helper('domains', success=False)

    def test_wildcard_issuance_ignores_child_policy(self):
        self.private_json('site-inventory.json', {'sites': {'site': {
            'canonical_hostname': 'www.example.com', 'aliases': []}}})
        self.write_fixture('ct.json', [self.cert(sans='*.example.com')])
        self.run_helper('ct')
        self.write_fixture('dns.json', {
            'example.com': [[0, 'issue', 'letsencrypt.org']],
            'www.example.com': [[0, 'issue', ';']]})
        self.assertEqual(self.run_helper('caa'), [])

    def test_unknown_critical_caa_is_not_permission(self):
        self.write_fixture('ct.json', [self.cert()])
        self.run_helper('ct')
        self.write_fixture('dns.json', {'example.com': [[128, 'new-property', 'value']]})
        self.assertEqual([f['kind'] for f in self.run_helper('caa')], ['caa-unknown'])

    def test_shell_boundary_rechecks_visibility_and_reserved_slug(self):
        body = self.home / 'body.md'
        body.write_text('operator finding')
        for slug in ('owner/public', 'MARCUSQUINN/AIDEVOPS'):
            self.write_fixture('visibility.json', {'marcusquinn/aidevops': 'PRIVATE'})
            result = subprocess.run([BASH, str(self.helper), '__file_issue', slug,  # nosec B603 -- fixed helper and synthetic fixture slugs, no shell evaluation
                                     'test', str(body), 'high'], env=self.env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.fixture_dir / 'writes.json').exists())

    def test_fleet_domain_repo_value_uses_owner(self):
        self.private_json('hosting-fleet.json', {'owner': 'owner', 'site_repos': {'example.com': 'private'}})
        self.run_helper('run', '--apply')
        writes = json.loads((self.fixture_dir / 'writes.json').read_text())
        self.assertTrue(writes)
        self.assertTrue(all(args[args.index('--repo') + 1] == 'owner/private' for args in writes))

    def test_invalid_state_is_not_rebaselined(self):
        self.run_helper('ct')
        for content in ('[]', '{}', '{"certificates": [], "pending": []}'):
            self.state.write_text(content)
            self.run_helper('ct', success=False)
            self.assertEqual(self.state.read_text(), content)

    def test_offset_expired_certificate_is_not_active(self):
        cert = self.cert()
        offset = dt.timezone(dt.timedelta(hours=5))
        cert['not_after'] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=1)).astimezone(offset).isoformat()
        self.write_fixture('ct.json', [cert])
        self.run_helper('ct')
        self.write_fixture('dns.json', {'example.com': [[0, 'issue', ';']]})
        self.assertEqual(self.run_helper('caa'), [])

    def test_core_entry_and_description_render(self):
        probe = self.home / 'routine-probe.sh'
        probe.write_text('source "$1"\nget_core_routine_entries\ndescribe_r923 linux\n')
        result = subprocess.run([BASH, str(probe), str(SOURCE / 'routines/core-routines.sh')],  # nosec B603 -- fixed local probe and repository-owned routine source
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('r923|x|Cert watch', result.stdout)
        self.assertIn('# r923: Certificate Transparency and CAA watch', result.stdout)
        self.assertIn('repeat:daily(@06:40)', result.stdout)

    def test_unknown_caa_does_not_consume_new_issuer_check(self):
        self.write_fixture('ct.json', [self.cert()])
        self.run_helper('ct')
        self.write_fixture('ct.json', [self.cert(2, 'Unexpected CA')])
        self.write_fixture('dns.json', {'example.com': None})
        self.assertEqual([f['kind'] for f in self.run_helper('ct')], ['ct-policy-unknown'])
        frozen = json.loads(self.state.read_text())['deferred_issuer_checks']['2']
        self.assertNotIn('unexpected ca', frozen)
        self.write_fixture('dns.json', {})
        self.assertEqual([f['kind'] for f in self.run_helper('ct')], ['ct-unexpected-issuer'])
        self.assertEqual(json.loads(self.state.read_text())['deferred_issuer_checks'], {})
        self.assertTrue(json.loads(self.state.read_text())['pending'])
        self.run_helper('run', '--apply')
        self.assertEqual(json.loads(self.state.read_text())['pending'], [])
        before = json.loads((self.fixture_dir / 'issues.json').read_text())
        self.run_helper('run', '--apply')
        self.assertEqual(json.loads((self.fixture_dir / 'issues.json').read_text()), before)


if __name__ == '__main__':
    unittest.main()
