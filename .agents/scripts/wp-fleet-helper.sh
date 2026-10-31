#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Private, explicitly approved WordPress fleet operations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
if [[ "${1:-}" == "core-minor" ]]; then
	shift
	# Kept self-contained so the SSH payload and controller always share a version.
	python3 - "$@" <<'PY'
import argparse
import fcntl
import json
import os
import re
import shlex
import subprocess
from pathlib import Path

REMOTE = r'''
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

os.umask(0o077)
request = json.loads(sys.argv[1])
site = request['site']
root = Path(site['wp_path']).resolve(strict=True)
if not (root / 'wp-config.php').is_file():
    raise RuntimeError('WordPress root with wp-config.php required')
stage = 'inspect'
config_hash = hashlib.sha256((root / 'wp-config.php').read_bytes()).hexdigest()

def wp(*args):
    return subprocess.check_output(['wp', '--path=' + str(root), '--skip-plugins',
                                    '--skip-themes', *args], stderr=subprocess.PIPE,
                                   timeout=600).decode().removesuffix('\n')

def version(value):
    if not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', value):
        raise RuntimeError('Stable numeric core version required')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))

def get(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        if urllib.parse.urlsplit(response.url).hostname != urllib.parse.urlsplit(url).hostname:
            raise RuntimeError('Cross-host download redirect refused')
        return response.read()

def probe(url):
    if urllib.parse.urlsplit(url).scheme not in ('http', 'https'):
        raise RuntimeError('HTTP site URL required')
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            code = response.status
    except urllib.error.HTTPError as error:
        code = error.code
    if not (200 <= code < 400 or code in (401, 403)):
        raise RuntimeError('Home/login health probe failed')
    return code

def verify(target, locale):
    if wp('core', 'version') != target:
        raise RuntimeError('Installed core version differs from target')
    wp('core', 'verify-checksums', '--version=' + target, '--locale=' + locale)
    home = wp('option', 'get', 'home').rstrip('/')
    url = wp('option', 'get', 'siteurl').rstrip('/')
    return [probe(home + '/'), probe(url + '/wp-login.php')]

current = wp('core', 'version')
locale = wp('eval', 'global $wp_local_package; echo $wp_local_package ?: "en_US";')
if not re.fullmatch(r'[a-z]{2,3}(?:_[A-Za-z0-9]+)*', locale):
    raise RuntimeError('Invalid package locale')
branch = version(current)[:2]
if request['action'] == 'plan':
    query = urllib.parse.urlencode({'version': current, 'locale': locale})
    offers = json.loads(get('https://api.wordpress.org/core/version-check/1.7/?' + query))['offers']
    versions = [o['version'] for o in offers
                if re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', o.get('version', ''))]
    minors = [v for v in versions if version(v)[:2] == branch and version(v) > version(current)]
    majors = sorted(set(v for v in versions if version(v)[:2] > branch), key=version)
    result = {'current': current, 'locale': locale, 'config_hash': config_hash,
              'target': max(minors, key=version) if minors else current, 'majors': majors}
else:
    plan = request['plan']
    target = plan['target']
    if (version(target)[:2] != branch or version(target) < version(current)
            or locale != plan['locale'] or config_hash != plan['config_hash']):
        raise RuntimeError('Branch, downgrade or locale guard failed')
    storage = Path(site['backup_dir']).expanduser().resolve()
    # A caller must name an account-private directory, not another site's web root.
    if storage == root or root in storage.parents or storage in root.parents:
        raise RuntimeError('Backup storage must be separate from the web root')
    storage.mkdir(mode=0o700, parents=True, exist_ok=True)
    if storage.stat().st_mode & 0o077:
        raise RuntimeError('Backup directory must have mode 0700')
    identity = hashlib.sha256(str(root).encode()).hexdigest()
    locks = Path.home() / '.aidevops' / 'wp-core-minor-locks'
    locks.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (locks / (identity + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Re-read under the lock to reject changes since planning.
        current = wp('core', 'version')
        locale = wp('eval', 'global $wp_local_package; echo $wp_local_package ?: "en_US";')
        config_hash = hashlib.sha256((root / 'wp-config.php').read_bytes()).hexdigest()
        if (current not in (plan['current'], target) or locale != plan['locale']
                or config_hash != plan['config_hash']):
            raise RuntimeError('Core, locale or configuration changed since planning')
        journal = storage / (identity + '-' + target + '.json')
        backup = None
        if journal.exists():
            saved = json.loads(journal.read_text())
            if saved['plan'] == plan:
                backup = Path(saved['backup'])
                if (not backup.is_file() or backup.stat().st_size == 0 or
                        hashlib.sha256(backup.read_bytes()).hexdigest() != saved['sha256']):
                    raise RuntimeError('Saved backup is missing or corrupt')
        if current != target:
            stage = 'baseline-health'
            home = wp('option', 'get', 'home').rstrip('/')
            url = wp('option', 'get', 'siteurl').rstrip('/')
            probe(home + '/')
            probe(url + '/wp-login.php')
            stage = 'package'
            package = ('https://downloads.wordpress.org/release/' +
                       (locale + '/' if locale != 'en_US' else '') + 'wordpress-' + target + '.zip')
            data = get(package)
            expected = get(package + '.sha1').decode().strip().split()[0].lower()
            if not re.fullmatch(r'[0-9a-f]{40}', expected) or hashlib.sha1(data).hexdigest() != expected:
                raise RuntimeError('Package SHA1 mismatch')
            with tempfile.TemporaryDirectory(prefix='core-minor-', dir=storage) as temporary:
                work = Path(temporary)
                archive = work / 'core.zip'
                archive.write_bytes(data)
                # config get reads constants without bootstrapping WordPress HTTP.
                values = {key: wp('config', 'get', 'DB_' + key) for key in ('HOST', 'USER', 'PASSWORD', 'NAME')}
                def quote(value):
                    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'
                host = values['HOST']
                options = {'user': values['USER'], 'password': values['PASSWORD']}
                if ':' in host:
                    host, suffix = host.split(':', 1)
                    options['port' if suffix.isdigit() else 'socket'] = suffix
                options['host'] = host
                defaults = work / 'mysql.cnf'
                defaults.write_text('[client]\n' + ''.join(k + '=' + quote(v) + '\n' for k, v in options.items()))
                defaults.chmod(0o600)
                stage = 'database-backup'
                fd, name = tempfile.mkstemp(prefix=identity + '-', suffix='.sql', dir=storage)
                backup = Path(name)
                try:
                    with os.fdopen(fd, 'wb') as output:
                        environment = {k: v for k, v in os.environ.items() if not k.startswith('MYSQL')}
                        environment['MYSQL_TEST_LOGIN_FILE'] = str(work / 'no-login-paths')
                        # Shared hosting grants only per-database privileges; --lock-all-tables
                        # needs global RELOAD. WordPress tables are InnoDB, so one snapshot suffices.
                        subprocess.run(['mysqldump', '--defaults-file=' + str(defaults),
                                        '--single-transaction', '--quick', '--no-tablespaces',
                                        '--', values['NAME']],
                                       stdout=output, stderr=subprocess.PIPE, timeout=600, check=True,
                                       env=environment)
                    if backup.stat().st_size == 0:
                        raise RuntimeError('Empty database backup')
                except Exception:
                    backup.unlink(missing_ok=True)
                    raise
                pending = journal.with_suffix('.pending')
                pending.write_text(json.dumps({'plan': plan, 'backup': str(backup),
                                              'sha256': hashlib.sha256(backup.read_bytes()).hexdigest()}))
                pending.replace(journal)
                stage = 'core-update'
                wp('core', 'update', str(archive), '--version=' + target, '--force')
        # Also run DB migration on resumed target installs (an earlier run may have stopped here).
        if plan['current'] != target:
            if backup is None:
                raise RuntimeError('Resume requires saved database backup')
            stage = 'pre-migration-checksums'
            if wp('core', 'version') != target:
                raise RuntimeError('Core update did not reach target')
            wp('core', 'verify-checksums', '--version=' + target, '--locale=' + locale)
            stage = 'database-upgrade'
            multisite = wp('eval', 'echo is_multisite() ? "yes" : "no";') == 'yes'
            wp('core', 'update-db', *(['--network'] if multisite else []))
        stage = 'verify'
        result = dict(plan, verified=True, health=verify(target, locale),
                      backup=str(backup) if backup else None)
print(json.dumps(result))
'''

def main():
    parser = argparse.ArgumentParser(description='Core minor fleet: private JSON inventory; never rolls back')
    parser.add_argument('action', choices=['plan', 'deploy', 'report'])
    parser.add_argument('--inventory', type=Path)
    parser.add_argument('--run-dir', required=True, type=Path)
    parser.add_argument('--approve', action='store_true', help='Approve the exact saved plan for deployment')
    parser.add_argument('--retry-held', action='store_true', help='Explicitly retry held deployments with saved plans')
    args = parser.parse_args()
    os.umask(0o077)
    run = args.run_dir.expanduser().resolve()
    run.mkdir(mode=0o700, parents=True, exist_ok=True)
    if run.stat().st_mode & 0o077:
        parser.error('run-dir must have mode 0700')
    lock = (run / '.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    path = run / 'core-minor.json'
    if args.action == 'report':
        print(path.read_text())
        return 0
    if args.action == 'deploy':
        if not args.approve:
            parser.error('deploy requires --approve after reviewing the saved plan')
        rows = json.loads(path.read_text())
    else:
        if not args.inventory or path.exists():
            parser.error('plan requires --inventory and a fresh run-dir')
        inventory = json.loads(args.inventory.read_text())
        if not isinstance(inventory, list) or not inventory or not all(isinstance(s, dict) for s in inventory):
            parser.error('inventory must be a nonempty array of site objects')
        rows = [{'site': site} for site in inventory]
    for row in rows:
        site = row['site']
        try:
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', site['ssh_host']):
                raise ValueError('ssh_host must be an SSH config alias')
            if not all(isinstance(site[k], str) and site[k].startswith('/')
                       for k in ('wp_path', 'backup_dir')):
                raise ValueError('Absolute wp_path and private backup_dir required')
            if args.action == 'deploy' and ('plan' not in row or (row.get('hold') and not args.retry_held)):
                continue
            request = {'site': site, 'action': args.action, 'plan': row.get('plan')}
            guarded = ('stage = "bootstrap"\ntry:\n    exec(' + repr(REMOTE) + ')\n'
                       'except Exception:\n    print(json.dumps({"failed_stage": stage}))\n')
            command = shlex.join(['python3', '-c', 'import json\n' + guarded, json.dumps(request)])
            result = subprocess.run(['ssh', '-oBatchMode=yes', '-oConnectTimeout=15',
                                     site['ssh_host'], command], capture_output=True, timeout=1800)
            if result.returncode:
                # Raw remote errors can include DB credentials; never expose them.
                raise RuntimeError('Remote operation failed; inspect private site logs (no rollback)')
            response = json.loads(result.stdout)
            if 'failed_stage' in response:
                row['hold'] = 'Remote failure at ' + response['failed_stage'] + '; inspect private backup journal; no rollback'
            else:
                row['plan' if args.action == 'plan' else 'result'] = response
                row.pop('hold', None)
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, RuntimeError):
            row['hold'] = 'Inspect SSH, runtime, API, backup, drift and verification; no automatic rollback'
        temporary = path.with_suffix('.pending')
        temporary.write_text(json.dumps(rows, indent=2) + '\n')
        temporary.replace(path)
    held = sum(bool(r.get('hold')) for r in rows)
    updates = sum(r.get('plan', {}).get('target') != r.get('plan', {}).get('current')
                  for r in rows if 'plan' in r)
    majors = sum(bool(r.get('plan', {}).get('majors')) for r in rows)
    print(f'core-minor {args.action}: sites={len(rows)} updates={updates} major-offers={majors} holds={held} rollback=never')
    return 1 if held else 0

raise SystemExit(main())
PY
	exit "$?"
fi
exec python3 "${SCRIPT_DIR}/wp-fleet-runner.py" "$@"
