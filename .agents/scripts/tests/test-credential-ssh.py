#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#34950 isolated HOME ~/.ssh/config audit; synthetic keys and configs only."""
import json
import os
import shutil
import subprocess  # nosec B404
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import credential_audit
import credential_env
import credential_sshrules as credential_ssh


@unittest.skipUnless(shutil.which('ssh-keygen'), 'ssh-keygen required')
class SshConfigAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.ssh = self.home / '.ssh'
        self.ssh.mkdir(mode=0o700)
        self.marker = self.home / 'match-exec-ran'
        self.canary_arg = 'synthetic-34950-proxy-argument'
        self.env = dict(os.environ, HOME=str(self.home))

    def key(self, path, passphrase='', extra=('-t', 'ed25519')):
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['ssh-keygen', '-q', *extra, '-N', passphrase, '-f', str(path)],
                       check=True, capture_output=True, timeout=60)  # nosec B603 B607
        return path

    def write(self, path, text, mode=0o600):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(mode)
        return path

    def records(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / 'credential_audit.py'), 'ssh-config'],
                                env=self.env, capture_output=True, text=True, timeout=60)  # nosec B603
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(self.canary_arg, result.stdout + result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_identityfile_keys_via_include_and_loopback(self):
        custom = self.key(self.home / 'keys/github_custom')
        self.key(self.ssh / 'id_ed25519')
        protected = self.key(self.ssh / 'protected_key', 'synthetic-passphrase')
        local = self.key(self.home / '.vm/ssh/id_ed25519')
        self.write(self.ssh / 'config', 'Include fragments/*\nHost git\n  IdentityFile ~/keys/github_custom\n'
                   f'  IdentityFile {protected}\n  IdentityFile ~/.ssh/%h\n')
        self.write(self.ssh / 'fragments/vm', f'Host vm\n  HostName 127.0.0.1\n  IdentityFile {local}\n')
        found = {(r['file'], r['category']): r for r in self.records()}
        # First-value-wins: a wildcard block's loopback HostName never proves a key local.
        wild = self.key(self.home / 'keys/wild')
        self.write(self.ssh / 'fragments/wild', 'Host remote\n  HostName remote.example.invalid\n'
                   f'Host *\n  HostName 127.0.0.1\n  IdentityFile {wild}\n')
        wild_found = {(r['file'], r['category']): r for r in self.records()}
        self.assertEqual(wild_found[(str(wild), 'ssh-key-no-passphrase')]['severity'], 'high')
        self.assertEqual(found[(str(custom), 'ssh-key-no-passphrase')]['severity'], 'high')
        self.assertIn((str(self.ssh / 'id_ed25519'), 'ssh-key-no-passphrase'), found)
        self.assertNotIn((str(protected), 'ssh-key-no-passphrase'), found)
        loopback = found[(str(local), 'ssh-key-no-passphrase')]
        self.assertEqual((loopback['severity'], loopback.get('loopback_only')), ('low', True))

    def test_directives_report_keywords_without_running_match_exec(self):
        self.write(self.ssh / 'config', f'StrictHostKeyChecking no\nHost *\n  ForwardAgent yes\n'
                   f'  UserKnownHostsFile=/dev/null\nHost bastion\n  ForwardAgent yes\n'
                   f'  ProxyCommand nc {self.canary_arg} %h %p\nMatch host x exec "touch {self.marker}"\n'
                   '  ProxyCommand none\nInclude config\n')
        records = self.records()
        self.assertFalse(self.marker.exists())
        got = sorted((r['line'], r['name'], r['category']) for r in records if r['line'])
        self.assertEqual(got, [
            (1, 'StrictHostKeyChecking', 'ssh-hostkey-check-disabled'),
            (3, 'ForwardAgent', 'ssh-agent-forwarding-global'),
            (4, 'UserKnownHostsFile', 'ssh-known-hosts-discarded'),
            (7, 'ProxyCommand', 'ssh-command-directive'),
            (8, 'Match exec', 'ssh-command-directive'),
        ])
        scan = subprocess.run(['bash', str(SCRIPTS / 'secret-hygiene-helper.sh'), 'scan-secrets'],
                              env=self.env, capture_output=True, text=True, timeout=120)  # nosec B603 B607
        self.assertIn('ssh-hostkey-check-disabled', scan.stdout)
        self.assertNotIn(self.canary_arg, scan.stdout + scan.stderr)
        self.assertFalse(self.marker.exists())

    def test_loose_unencrypted_pem_and_repeated_include_scopes(self):
        # ssh-keygen -y refuses 0644 keys; format inspection must still flag them.
        loose = self.key(self.home / 'keys/loose')
        loose.chmod(0o644)
        pem = self.key(self.home / 'keys/pem_plain', extra=('-t', 'rsa', '-b', '2048', '-m', 'PEM'))
        pem_locked = self.key(self.home / 'keys/pem_locked', 'synthetic-passphrase',
                              extra=('-t', 'rsa', '-b', '2048', '-m', 'PEM'))
        self.write(self.ssh / 'common', 'ForwardAgent yes\n')
        self.write(self.ssh / 'config', f'Host private\n  Include common\n  IdentityFile {loose}\n'
                   f'  IdentityFile {pem}\n  IdentityFile {pem_locked}\nHost *\n  Include common\n')
        found = {(r['file'], r['line'], r['category']) for r in self.records()}
        self.assertIn((str(loose), 0, 'insecure-perms'), found)
        self.assertIn((str(loose), 0, 'ssh-key-no-passphrase'), found)
        self.assertIn((str(pem), 0, 'ssh-key-no-passphrase'), found)
        self.assertNotIn((str(pem_locked), 0, 'ssh-key-no-passphrase'), found)
        self.assertIn((str(self.ssh / 'common'), 1, 'ssh-agent-forwarding-global'), found)

    def test_permissions_symlinks_and_confirmation(self):
        self.ssh.chmod(0o755)
        key = self.key(self.ssh / 'id_ed25519', 'synthetic-passphrase')
        key.chmod(0o644)
        real = self.write(self.home / 'dotfiles/ssh_config', 'Host a\n', 0o644)
        (self.ssh / 'config').symlink_to(real)
        found = {(r['file'], r['category']): r for r in self.records()}
        self.assertEqual(found[(str(self.ssh), 'ssh-dir-perms')]['severity'], 'low')
        self.assertEqual(found[(str(key), 'insecure-perms')]['env_source'], 'ssh')
        self.assertEqual(found[(str(key), 'insecure-perms')]['severity'], 'high')
        self.assertIn((str(self.ssh / 'config'), 'ssh-insecure-perms-symlink'), found)
        self.assertNotIn((str(self.ssh / 'config'), 'insecure-perms'), found)
        records = [found[(str(key), 'insecure-perms')]]
        self.assertEqual(credential_env.confirmed_permissions(records, lambda _label: False), [])
        prompts = []
        self.assertEqual(credential_env.confirmed_permissions(records, lambda label: prompts.append(label) or True),
                         records)
        self.assertTrue(prompts[0].startswith('SSH config/key chmod 600'))

    def test_unchmodable_target_does_not_stop_other_permission_fixes(self):
        stub = self.write(self.home / 'stub/audit-log-helper.sh', '#!/bin/sh\nexit 0\n', 0o700)
        target = self.write(self.home / 'loose', 'x', 0o644)
        records = [{'category': 'insecure-perms', 'file': str(self.home / 'vanished')},
                   {'category': 'insecure-perms', 'file': str(target)}]
        credential_audit.fix_permissions(records, stub.parent)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_parser_and_expansion_edges(self):
        self.assertEqual(credential_ssh.parse_line('  Host = "a b" c # note'), ('host', ['a b', 'c']))
        self.assertEqual(credential_ssh.parse_line('IdentityFile=~/k'), ('identityfile', ['~/k']))
        self.assertIsNone(credential_ssh.parse_line('# comment'))
        self.assertIsNone(credential_ssh.parse_line('ProxyCommand "unbalanced'))
        self.assertEqual(credential_ssh.expand('/h', 'u', '%d/.ssh/%u'), '/h/.ssh/u')
        self.assertIsNone(credential_ssh.expand('/h', 'u', '~/.ssh/%h'))
        self.assertIsNone(credential_ssh.expand('/h', 'u', 'relative_key'))
        self.assertIsNone(credential_ssh.expand('/h', 'u', '${KEY_DIR}/k'))


if __name__ == '__main__':
    unittest.main()
