#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Offline fleet protocol/filesystem tests; no SSH or production credentials.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/../shared-constants.sh"
python3 - "${SCRIPT_DIR}/.." <<'PY'
import contextlib
import copy
import importlib.util
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

scripts = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location('fleet', str(scripts / 'wp-fleet-runner.py'))
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)
os.umask(0o077)
count = 0

def check(name, condition):
    global count
    assert condition, name
    count += 1
    print('PASS ' + name)

def stopped(name, callback):
    try:
        callback()
    except fleet.Stop:
        check(name, True)
    else:
        raise AssertionError(name)

def bundle(version='2.0', member=None):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as archive:
        archive.writestr('sample/sample.php', '<?php\n/* Plugin Name: Sample\nVersion: ' + version + '\n*/')
        archive.writestr(member or 'sample/lib.php', '<?php // release')
    return data.getvalue()

base = os.environ.get('AIDEVOPS_TEMP_DIR')
if not base:
    base = str(Path.home() / '.aidevops' / '.agent-workspace' / 'tmp')
    Path(base).mkdir(mode=0o700, parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='aidevops-wp-fleet-', dir=base) as temporary:
    temp = Path(temporary)
    home = temp / 'home'
    home.mkdir(mode=0o700)
    os.environ['HOME'] = str(home)
    config = home / '.config' / 'aidevops'
    config.mkdir(parents=True)
    registry = {'servers': {'shared': {'ssh_host': 'fixture-host', 'ssh_password_env': 'FIXTURE_REF'}},
                'sites': {'one': {'server_ref': 'shared', 'wp_path': '/fixture/site',
                                  'category': 'fixture', 'secret_field': 'NOT_FOR_EXPORT'}}}
    (config / 'wordpress-sites.json').write_text(json.dumps(registry))
    exported = subprocess.check_output(['bash', str(scripts / 'wp-helper.sh'), '--export-sites'])
    row = json.loads(exported)
    check('allowlisted shared server export', row['ssh_password_env'] == 'FIXTURE_REF' and
          row['ssh_host'] == 'fixture-host' and b'NOT_FOR_EXPORT' not in exported)
    subprocess.check_call(['bash', str(scripts / 'wp-fleet-helper.sh'), '--help'], stdout=subprocess.DEVNULL)
    parent = temp / 'sites'
    parent.mkdir()
    root = parent / 'one'
    root.mkdir()
    (root / 'wp-config.php').write_text('<?php // private config')
    plugin = root / 'wp-content' / 'plugins' / 'sample'
    plugin.mkdir(parents=True)
    (plugin / 'sample.php').write_text('<?php\n/* Plugin Name: Sample\nVersion: 1.0\n*/')
    storage = str(temp / 'backups')
    artifact = bundle()
    release = {'version': '2.0', 'sha256': fleet.digest(artifact),
               'files': fleet.archive(artifact, 'sample', '2.0')}
    request = {'action': 'inspect', 'root': str(root), 'parent': str(parent), 'slug': 'sample'}
    urls = ['https://fixture.invalid/', 'https://fixture.invalid/staging/']
    activation = {urls[0]: 'active', urls[1]: 'inactive'}
    installed = ['1.0']
    mutations = []
    fail_dump = [False]
    audit_calls = []
    def wp(path, *args):
        assert path == str(root)
        if args[:2] == ('plugin', 'path'):
            return str(plugin)
        if args[:2] == ('plugin', 'get'):
            return json.dumps({'version': installed[0], 'status': 'active'})
        if args[:2] == ('config', 'list'):
            return json.dumps([{'name': 'MULTISITE', 'value': 'true'}])
        if args[:2] == ('site', 'list'):
            return json.dumps([{'url': u} for u in urls])
        if args[0].startswith('--url='):
            if args[1:3] == ('plugin', 'get'):
                return json.dumps({'status': activation[args[0][6:]]})
            audit_calls.append(args)
            return 'audit passed'
        if args[:2] == ('db', 'export'):
            Path(args[2]).write_text('-- fixture SQL dump\nCREATE TABLE fixture (id int);')
            if fail_dump[0]:
                raise fleet.Stop('fixture interrupted backup')
            return ''
        if args[:2] == ('plugin', 'install'):
            check('upgrader has no activation flags', args[-1] == '--force' and len(args) == 4)
            mutations.append(args)
            shutil.rmtree(str(plugin))
            with zipfile.ZipFile(args[2]) as archive:
                archive.extractall(str(plugin.parent))
            installed[0] = '2.0'
            return ''
        raise AssertionError(args)
    fleet.wp = wp
    fleet.health = lambda url: 401 if url.endswith('/staging/') else 200
    baseline = fleet.snapshot(request)
    check('multisite URLs and individual health states', baseline['urls'] == sorted(urls) and
          baseline['health'][urls[1]] == 401 and baseline['activation'] == activation)
    alias = parent / 'alias'
    alias.symlink_to(root, target_is_directory=True)
    check('canonical alias dedup identity', fleet.snapshot(dict(request, root=str(alias))) == baseline)
    stopped('scan parent escape', lambda: fleet.snapshot(dict(request, parent=str(root))))
    stopped('unsafe archive traversal', lambda: fleet.archive(bundle(member='sample/../escape'), 'sample', '2.0'))
    stopped('unsafe archive dot alias', lambda: fleet.archive(bundle(member='sample/./lib.php'), 'sample', '2.0'))
    collision = io.BytesIO()
    with zipfile.ZipFile(collision, 'w') as z:
        z.writestr('sample/sample.php', '<?php\n/* Plugin Name: Sample\nVersion: 2.0\n*/')
        z.writestr('sample/lib', 'file')
        z.writestr('sample/lib/file.php', 'collision')
    stopped('archive file/directory collision', lambda: fleet.archive(collision.getvalue(), 'sample', '2.0'))
    stopped('wrong plugin version', lambda: fleet.archive(bundle(), 'sample', '9.0'))
    stopped('newer version refusal', lambda: fleet.version_guard('3.0', '2.0'))
    stopped('unknown version ordering refusal', lambda: fleet.version_guard('2.0-beta', '2.0'))
    phase = dict(request, baseline=baseline, preflight=baseline, release=release,
                 storage=storage, fingerprint='a' * 64)
    stopped('deploy without complete backup', lambda: fleet.remote(dict(phase, action='deploy')))
    fail_dump[0] = True
    stopped('interrupted backup', lambda: fleet.remote(dict(phase, action='backup')))
    run = Path(storage) / phase['fingerprint']
    check('incomplete backup not published', not list(run.glob('*.json')) and not list(run.glob('.backup-*')))
    fail_dump[0] = False
    backup = fleet.remote(dict(phase, action='backup'))
    check('verified reusable backup', fleet.remote(dict(phase, action='backup')) == backup)
    missing = copy.deepcopy(backup)
    del missing['backup'][fleet.digest(str(root).encode()) + '/database.sql']
    stopped('partial backup manifest refused', lambda: fleet.check_backup(missing, run, phase))
    check('private backup modes', all(stat.S_IMODE((run / p).stat().st_mode) == 0o600 for p in backup['backup']))
    bad = dict(phase, action='deploy', artifact=fleet.base64.b64encode(b'wrong').decode())
    stopped('checksum mismatch before mutation', lambda: fleet.remote(bad))
    check('no mutation on guard failures', not mutations)
    identity = fleet.digest(str(root).encode())
    lock = home / '.aidevops' / 'wp-fleet-locks' / (identity + '.lock')
    lock.mkdir()
    stopped('lock contention across storage/run IDs', lambda: fleet.remote(dict(phase, action='backup', storage=str(temp / 'other'))))
    lock.rmdir()
    applied = dict(phase, action='deploy', artifact=fleet.base64.b64encode(artifact).decode())
    result = fleet.remote(applied)
    check('normal upgrader bytes and unchanged activation', result['deployed'] and
          result['state']['activation'] == activation and fleet.matches(result['state'], release))
    applied['preflight'] = fleet.snapshot(request)
    check('exact byte resume skips reinstall', fleet.remote(applied)['skipped'] and len(mutations) == 1)
    verified = fleet.remote(dict(applied, action='verify', audit_argv=['sample', 'audit']))
    check('read-only audit on every logical URL', verified['verified'] and len(audit_calls) == 2)
    stopped('audit path override refusal', lambda: fleet.remote(dict(applied, action='verify', audit_argv=['--path=/other'])))
    (plugin / 'lib.php').write_text('tampered')
    stopped('target version with changed bytes is not skipped', lambda: fleet.remote(applied))
    stopped('read-only failure performs no rollback', lambda: fleet.remote(dict(applied, action='verify')))
    check('failed verification leaves user data/backups untouched', (plugin / 'lib.php').read_text() == 'tampered' and
          (root / 'wp-config.php').read_text() == '<?php // private config' and len(mutations) == 1)
    fleet.check_backup(backup, run, phase)
    saved = (run / next(iter(backup['backup'])))
    saved.write_text('corrupt')
    stopped('corrupt backup is not reusable', lambda: fleet.check_backup(backup, run, phase))
    stopped('unknown checkpoint schema', lambda: fleet.check_backup(dict(backup, schema=99), run, phase))
    # Published release pinning/plan flow with isolated API and transport stubs.
    original_command = fleet.command
    original_transport = fleet.transport
    original_inventory = fleet.inventory
    release_data = {'draft': False, 'id': 10, 'assets': [{'name': 'sample.zip', 'id': 20,
                    'digest': 'sha256:' + release['sha256']}]}
    tag_ref = {'object': {'type': 'tag', 'sha': 'tag-object'}}
    tag_data = {'object': {'type': 'commit', 'sha': 'commit'},
                'verification': {'verified': True, 'reason': 'valid'}}
    ci_data = {'workflow_runs': [{'status': 'completed', 'conclusion': 'success'}]}
    def github(argv, data=None, timeout=120, env=None):
        assert argv[:2] == ['gh', 'api']
        endpoint = argv[2]
        if '/releases/tags/' in endpoint:
            value = release_data
        elif '/git/ref/tags/' in endpoint:
            value = tag_ref
        elif '/git/tags/' in endpoint:
            value = tag_data
        elif '/actions/runs?' in endpoint:
            value = ci_data
        elif '/releases/assets/' in endpoint:
            return artifact
        else:
            raise AssertionError(endpoint)
        return json.dumps(value).encode()
    fleet.command = github
    fleet.inventory = lambda args: [dict(row, wp_path=str(root)), dict(row, id='alias', wp_path=str(alias))]
    fleet.transport = lambda site, req: {'python': True} if req['action'] == 'probe' else copy.deepcopy(baseline)
    health_file = temp / 'health.json'
    health_file.write_text(json.dumps(baseline['health']))
    plan_args = fleet.argparse.Namespace(slug='sample', repository='fixture/sample', tag='v2.0',
        asset='sample.zip', version='2.0', sha256=release['sha256'], scan_parent=str(parent),
        sites='one,alias', category=None, tenant=None, remote_storage=storage,
        discover_ssh=None, health=str(health_file), trust_decision=None,
        audit_argv=None, audit_read_only=False)
    planned = fleet.private_dir(temp / 'plan')
    with contextlib.redirect_stdout(io.StringIO()):
        fleet.create_plan(plan_args, planned)
    sealed = json.loads((planned / 'manifest.json').read_text())
    check('plan deduplicates aliases and seals every logical URL', len(sealed['installations']) == 1 and
          len(sealed['aliases']) == 2 and sealed['fingerprint'] == fleet.fingerprint(sealed) and
          sealed['installations'][0]['baseline']['urls'] == sorted(urls))
    tag_data['verification']['verified'] = False
    stopped('unverified signature stops without trust decision', lambda: fleet.release_check(sealed['release']))
    trusted = copy.deepcopy(sealed['release'])
    trusted['signature'] = copy.deepcopy(tag_data['verification'])
    trusted['trust_decision'] = 'fixture operator decision'
    fleet.release_check(trusted)
    check('explicit signature trust decision is recorded', trusted['trust_decision'])
    tag_data['verification']['verified'] = True
    ci_data['workflow_runs'][0]['conclusion'] = 'failure'
    stopped('failed exact commit CI refuses release', lambda: fleet.release_check(sealed['release']))
    ci_data['workflow_runs'][0]['conclusion'] = 'success'
    release_data['assets'][0]['digest'] = 'sha256:' + '0' * 64
    stopped('trusted asset digest mismatch refuses release', lambda: fleet.release_check(sealed['release']))
    release_data['assets'][0]['digest'] = 'sha256:' + release['sha256']
    plan_args.health = None
    stopped('non-200 baseline needs explicit per-URL expectation',
            lambda: fleet.create_plan(plan_args, fleet.private_dir(temp / 'bad-health-plan')))
    fleet.command = original_command
    fleet.inventory = original_inventory
    # Execute the real SSH Python launcher locally, without opening a connection.
    def local_ssh(argv, data=None, timeout=120, env=None):
        assert 'ConnectTimeout=20' in argv
        return subprocess.check_output(['bash', '-c', argv[-1]], input=data, env=env)
    fleet.command = local_ssh
    check('remote Python source/protocol bootstrap', original_transport({'ssh_host': 'fixture-host'}, {'action': 'probe'})['python'])
    fleet.command = original_command
    # Coordinator guards run before transport and preserve complete evidence on
    # failure; replacing only transports keeps the production phase path intact.
    directory = fleet.private_dir(temp / 'coordinator')
    installation = {'site': row, 'baseline': baseline, 'request': request}
    manifest = {'schema': 1, 'release': release, 'installations': [installation],
                'inventory': [row], 'aliases': [installation],
                'selection': {'sites': 'one', 'category': None, 'tenant': None,
                              'scan_parent': str(parent), 'slug': 'sample', 'storage': storage,
                              'discover_ssh': None, 'audit_argv': None}}
    manifest['fingerprint'] = fleet.fingerprint(manifest)
    fleet.atomic(directory / 'manifest.json', manifest)
    (directory / 'release.zip').write_bytes(artifact)
    args = fleet.argparse.Namespace(phase='deploy', apply=False, approve=manifest['fingerprint'])
    stopped('deploy requires explicit apply', lambda: fleet.run_phase(args, directory))
    args.apply = True
    args.approve = 'wrong'
    stopped('deploy requires exact approval', lambda: fleet.run_phase(args, directory))
    args.approve = manifest['fingerprint']
    fleet.release_check = lambda value: None
    fleet.inventory = lambda value: []
    stopped('fleet inventory drift before writes', lambda: fleet.run_phase(args, directory))
    fleet.inventory = lambda value: [row]
    fleet.transport = lambda site, req: dict(baseline, urls=['https://new.invalid/'])
    stopped('logical URL drift before writes', lambda: fleet.run_phase(args, directory))
    fleet.transport = lambda site, req: dict(baseline, activation={})
    stopped('activation drift before writes', lambda: fleet.run_phase(args, directory))
    fleet.transport = lambda site, req: dict(baseline, config_sha256='changed')
    stopped('config drift before writes', lambda: fleet.run_phase(args, directory))
    calls = []
    def preflight_transport(site, req):
        calls.append(req['action'])
        if req['action'] == 'check-backup':
            raise fleet.Stop('fixture missing fleet backup')
        return copy.deepcopy(baseline)
    fleet.transport = preflight_transport
    stopped('fleet-wide complete backup preflight', lambda: fleet.run_phase(args, directory))
    check('no deploy before all fleet backups verified', 'deploy' not in calls)
    # A partial phase failure retains completed-site evidence atomically.
    second = copy.deepcopy(installation)
    second['site']['id'] = 'two'
    manifest['installations'].append(second)
    manifest['fingerprint'] = fleet.fingerprint(manifest)
    fleet.atomic(directory / 'manifest.json', manifest)
    args.phase = 'verify'
    def partial_transport(site, req):
        if req['action'] == 'verify':
            if site['id'] == 'two':
                raise fleet.Stop('fixture interrupted phase')
            return {'verified': True}
        return copy.deepcopy(baseline)
    fleet.transport = partial_transport
    stopped('interrupted phase checkpoints completed installations', lambda: fleet.run_phase(args, directory))
    evidence = json.loads((directory / 'evidence.json').read_text())
    check('completed evidence survives partial failure', evidence['status'] == 'stopped' and len(evidence['completed']) == 1)
    fleet.transport = lambda site, req: {'verified': True} if req['action'] == 'verify' else copy.deepcopy(baseline)
    with contextlib.redirect_stdout(io.StringIO()):
        fleet.run_phase(args, directory)
    check('resume revalidates and keeps historical evidence', len(list(directory.glob('evidence-*.json'))) == 1 and
          json.loads((directory / 'evidence.json').read_text())['status'] == 'complete')
    fleet.atomic(directory / 'manifest.json', dict(manifest, schema=99))
    stopped('unknown manifest schema', lambda: fleet.run_phase(args, directory))
    fleet.atomic(directory / 'manifest.json', manifest)
    result = subprocess.run(['bash', str(scripts / 'wp-fleet-helper.sh'), 'deploy', '--run-dir', str(directory)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check('CLI refuses unapproved deployment without contacting hosts', result.returncode == 1 and
          (directory / 'recovery.json').exists() and b'fixture' not in result.stderr)
    report = subprocess.check_output(['bash', str(scripts / 'wp-fleet-helper.sh'), 'report', '--run-dir', str(directory)])
    check('public report is sanitized', json.loads(report)['installations'] == 2 and b'fixture' not in report)
print('Tests: %d passed' % count)
PY
