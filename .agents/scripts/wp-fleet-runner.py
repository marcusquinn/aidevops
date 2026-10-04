#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private fleet coordinator and bounded SSH RPC; remote side is Python 3.6 compatible.

No shell supplied by a release is executed. Remote stdout is a JSON protocol,
never a public log. Errors deliberately exclude subprocess output and paths.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import shlex
import subprocess  # nosec B404 -- only for exception classes; commands use wp_fleet_guards.command
import sys
import zipfile

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import wp_fleet_remote as rpc  # noqa: E402
from wp_fleet_guards import (SCHEMA, Stop, archive, atomic, audit_guard, command, digest,  # noqa: E402
                             encoded, matches, private_dir, require, scope_guard, version_guard)
from wp_fleet_remote import check_backup, remote, snapshot  # noqa: E402

# Re-exported for the focused shell test; the coordinator itself uses rpc.* remotely.
__all__ = ['Stop', 'archive', 'atomic', 'check_backup', 'command', 'create_plan', 'digest',
           'fingerprint', 'inventory', 'matches', 'private_dir', 'release_check', 'remote',
           'rpc', 'run_phase', 'snapshot', 'transport', 'version_guard']

# Remote modules are shipped as source and registered before import, in order.
REMOTE_MODULES = ('wp_fleet_guards', 'wp_fleet_remote')
LAUNCHER = """import json,sys,types
for name,source in %r:
    module=types.ModuleType(name)
    sys.modules[name]=module
    exec(compile(source,name,'exec'),module.__dict__)
from wp_fleet_guards import Stop
from wp_fleet_remote import remote
try:
    print(json.dumps({'result':remote(json.load(sys.stdin))}))
except Stop as error:
    print(json.dumps({'error':str(error)}))
except Exception:
    print(json.dumps({'error':'remote operation failed; private checkpoint retained'}))
"""
SSH_OPTIONS = (('ssh_user', '-l'), ('ssh_port', '-p'), ('ssh_identity_file', '-i'))
SSH_ALIAS = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]*')
FINGERPRINT_KEYS = ('schema', 'release', 'installations', 'selection', 'inventory', 'aliases')


def _launcher():
    modules = [(name, (SCRIPT_DIR / (name + '.py')).read_text(encoding='utf-8')) for name in REMOTE_MODULES]
    return LAUNCHER % (modules,)


def _ssh_argv(site, env):
    host = site['ssh_host']
    require(isinstance(host, str) and SSH_ALIAS.fullmatch(host), 'invalid SSH alias')
    argv = ['ssh', '-o', 'ConnectTimeout=20']
    reference = site.get('ssh_password_env')
    if reference:
        require(env.get(reference), 'shared SSH credential unavailable')
        env['SSHPASS'] = env[reference]
        argv = ['sshpass', '-e'] + argv
    else:
        argv += ['-o', 'BatchMode=yes']
    for key, flag in SSH_OPTIONS:
        if site.get(key):
            argv += [flag, str(site[key])]
    return argv + [host]


def transport(site, request):
    env = dict(os.environ)
    argv = _ssh_argv(site, env) + ['python3 -c ' + shlex.quote(_launcher())]
    response = json.loads(command(argv, encoded(request), timeout=600, env=env))
    if 'error' in response:
        raise Stop(response['error'])
    return response['result']


def _discover_inventory(args):
    require(args.scan_parent and not args.sites and not args.category,
            'discovery requires exclusive explicit SSH selection')
    site = {'ssh_host': args.discover_ssh}
    roots = transport(site, {'action': 'discover', 'parent': args.scan_parent})
    require(roots, 'discovery found no installations')
    return [dict(site, id=str(n), wp_path=root) for n, root in enumerate(roots)]


def inventory(args):
    if args.discover_ssh:
        return _discover_inventory(args)
    argv = ['bash', str(SCRIPT_DIR / 'wp-helper.sh')]
    if args.tenant:
        argv += ['--tenant', args.tenant]
    sites = [json.loads(line) for line in command(argv + ['--export-sites']).decode().splitlines()]
    ids = set(args.sites.split(',')) if args.sites else set()
    selected = [s for s in sites if s['id'] in ids or (args.category and s.get('category') == args.category)]
    require(selected, 'explicit nonempty site selection required')
    require(ids <= {s['id'] for s in selected}, 'selected site missing')
    return selected


def fingerprint(manifest):
    return digest(encoded({key: manifest[key] for key in FINGERPRINT_KEYS}))


def _gh_json(endpoint):
    return json.loads(command(['gh', 'api', endpoint]))


def _check_tag(release):
    repo, tag = release['repository'], release['tag']
    ref = _gh_json('repos/' + repo + '/git/ref/tags/' + tag)['object']
    require(ref['type'] == 'tag' and ref['sha'] == release['tag_object'], 'annotated tag changed')
    annotated = _gh_json('repos/' + repo + '/git/tags/' + ref['sha'])
    target = annotated['object']
    require(target['sha'] == release['commit'] and target['type'] == 'commit', 'tag commit changed')
    verification = annotated['verification']
    require(verification == release['signature'], 'tag signature changed')
    require(verification['verified'] or release.get('trust_decision'),
            'tag signature unverified; explicit trust decision required')


def release_check(release):
    repo = release['repository']
    data = _gh_json('repos/' + repo + '/releases/tags/' + release['tag'])
    require(not data['draft'] and data['id'] == release['release_id'], 'published release identity changed')
    assets = [a for a in data['assets'] if a['name'] == release['asset']]
    require(len(assets) == 1 and assets[0]['id'] == release['asset_id'], 'trusted asset changed')
    require(assets[0].get('digest') == 'sha256:' + release['sha256'], 'trusted asset digest mismatch')
    _check_tag(release)
    runs = _gh_json('repos/' + repo + '/actions/runs?head_sha=' + release['commit'] + '&per_page=100')['workflow_runs']
    require(runs and all(r['status'] == 'completed' and r['conclusion'] == 'success' for r in runs),
            'successful exact-commit CI required')


def _validate_plan_args(args, directory):
    require(args.slug and re.fullmatch(r'[a-z0-9-]+', args.slug), 'explicit plugin slug required')
    require(args.repository and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository),
            'explicit repository required')
    require(all((args.tag, args.asset, args.version, args.sha256, args.scan_parent)),
            'release identity, trusted checksum and scan parent required')
    require(re.fullmatch(r'[a-f0-9]{64}', args.sha256), 'invalid trusted checksum')
    require(not (directory / 'manifest.json').exists(), 'run already exists; use phase/resume')


def _pin_release(args):
    """Resolve the published release once; return (release identity, verified artifact)."""
    data = _gh_json('repos/' + args.repository + '/releases/tags/' + args.tag)
    assets = [a for a in data['assets'] if a['name'] == args.asset]
    require(len(assets) == 1, 'published asset missing or ambiguous')
    ref = _gh_json('repos/' + args.repository + '/git/ref/tags/' + args.tag)['object']
    require(ref['type'] == 'tag', 'signed annotated tag required')
    tag = _gh_json('repos/' + args.repository + '/git/tags/' + ref['sha'])
    release = {'repository': args.repository, 'tag': args.tag, 'asset': args.asset,
               'version': args.version, 'sha256': args.sha256, 'release_id': data['id'],
               'asset_id': assets[0]['id'], 'tag_object': ref['sha'], 'commit': tag['object']['sha'],
               'signature': tag['verification'], 'trust_decision': args.trust_decision}
    release_check(release)
    artifact = command(['gh', 'api', 'repos/' + args.repository + '/releases/assets/' + str(assets[0]['id']),
                        '-H', 'Accept: application/octet-stream'])
    require(digest(artifact) == args.sha256, 'downloaded checksum mismatch')
    release['files'] = archive(artifact, args.slug, args.version)
    return release, artifact


def _plan_selection(args):
    audit = json.loads(args.audit_argv) if args.audit_argv else None
    require(not audit or args.audit_read_only, 'operator read-only audit attestation required')
    if audit:
        audit_guard(audit)
    return {'sites': args.sites, 'category': args.category, 'tenant': args.tenant,
            'scan_parent': args.scan_parent, 'slug': args.slug, 'storage': args.remote_storage,
            'discover_ssh': args.discover_ssh, 'audit_argv': audit}


def _inspect_sites(manifest, args):
    """Record every alias, and one installation per canonical host/root."""
    expectations = json.loads(Path(args.health).read_text()) if args.health else {}
    seen = set()
    for site in manifest['inventory']:
        transport(site, {'action': 'probe'})  # detect Python before any staging
        request = {'action': 'inspect', 'root': site['wp_path'], 'parent': args.scan_parent, 'slug': args.slug}
        state = transport(site, request)
        version_guard(state['version'], args.version)
        require(all(code == expectations.get(url, 200) for url, code in state['health'].items()),
                'baseline health requires per-URL explicit expectation')
        entry = {'site': site, 'baseline': state, 'request': request}
        manifest['aliases'].append(entry)
        identity = (state['host_identity'], state['root'])
        if identity not in seen:
            seen.add(identity)
            manifest['installations'].append(entry)


def create_plan(args, directory):
    _validate_plan_args(args, directory)
    release, artifact = _pin_release(args)
    selection = _plan_selection(args)
    manifest = {'schema': SCHEMA, 'release': release, 'selection': selection,
                'installations': [], 'inventory': inventory(args), 'aliases': []}
    _inspect_sites(manifest, args)
    manifest['fingerprint'] = fingerprint(manifest)
    fd = os.open(str(directory / 'release.zip'), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(artifact)
    atomic(directory / 'manifest.json', manifest)
    print('Plan sealed: ' + manifest['fingerprint'])


def _load_json(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def _load_manifest(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    require(manifest.get('schema') == SCHEMA, 'unsupported manifest schema')
    require(manifest['fingerprint'] == fingerprint(manifest), 'plan fingerprint mismatch')
    return manifest


def _report(directory, manifest):
    evidence = _load_json(directory / 'evidence.json', {})
    print(json.dumps({'schema': SCHEMA, 'installations': len(manifest['installations']),
                      'completed': len(evidence.get('completed', [])), 'phase': evidence.get('phase', 'plan'),
                      'status': evidence.get('status', 'planned')}))


def _phase_request(installation, manifest, action, **extra):
    request = dict(installation['request'], action=action, baseline=installation['baseline'],
                   release=manifest['release'], fingerprint=manifest['fingerprint'],
                   storage=manifest['selection']['storage'])
    request.update(extra)
    return request


def _revalidate(args, directory, manifest):
    """Recheck release, artifact, inventory and every installation; return (artifact, states)."""
    release_check(manifest['release'])
    artifact = (directory / 'release.zip').read_bytes()
    require(digest(artifact) == manifest['release']['sha256'], 'private artifact checksum mismatch')
    slug, version = manifest['selection']['slug'], manifest['release']['version']
    require(archive(artifact, slug, version) == manifest['release']['files'], 'archive changed')
    # Every selected alias remains in the registry, including deduplicated aliases.
    current = inventory(argparse.Namespace(**manifest['selection']))
    require(manifest.get('inventory') == current, 'inventory drift; new plan approval required')
    for alias in manifest['aliases']:
        scope_guard(transport(alias['site'], alias['request']), alias['baseline'], manifest['release'])
    states = []
    for installation in manifest['installations']:
        state = transport(installation['site'], installation['request'])
        scope_guard(state, installation['baseline'], manifest['release'])
        states.append(state)
        if args.phase == 'deploy':
            transport(installation['site'], _phase_request(installation, manifest, 'check-backup'))
    return artifact, states


def _start_evidence(args, directory, manifest):
    previous = _load_json(directory / 'evidence.json')
    if previous is not None:
        # Keep historical completed-site evidence even if a later phase fails.
        atomic(directory / ('evidence-' + digest(encoded(previous)) + '.json'), previous)
    evidence = {'schema': SCHEMA, 'phase': args.phase, 'status': 'running', 'completed': [],
                'fingerprint': manifest['fingerprint'],
                'approval': args.approve if args.phase == 'deploy' else None}
    atomic(directory / 'evidence.json', evidence)
    return evidence


def _execute(args, directory, manifest, artifact, states):
    evidence = _start_evidence(args, directory, manifest)
    extra = {'audit_argv': manifest['selection']['audit_argv']}
    if args.phase == 'deploy':
        extra['artifact'] = base64.b64encode(artifact).decode()
    try:
        for installation, state in zip(manifest['installations'], states):
            request = _phase_request(installation, manifest, args.phase, preflight=state, **extra)
            result = transport(installation['site'], request)
            evidence['completed'].append({'identity': digest(encoded(installation)), 'result': result})
            atomic(directory / 'evidence.json', evidence)
        evidence['status'] = 'complete'
    except Exception:
        evidence['status'] = 'stopped'
        evidence['recovery'] = 'Inspect private backups/checkpoints; revalidate same phase or approve a new plan'
        raise
    finally:
        atomic(directory / 'evidence.json', evidence)


def run_phase(args, directory):
    manifest = _load_manifest(directory)
    if args.phase == 'report':
        _report(directory, manifest)
        return
    if args.phase == 'deploy':
        require(args.apply and args.approve == manifest['fingerprint'], 'exact fingerprint and --apply required')
    artifact, states = _revalidate(args, directory, manifest)
    _execute(args, directory, manifest, artifact, states)
    print('Phase complete: ' + args.phase)


def _parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['plan', 'backup', 'deploy', 'verify', 'report'])
    parser.add_argument('--run-dir', required=True)
    for name in ['slug', 'repository', 'tag', 'asset', 'version', 'sha256', 'sites', 'category',
                 'tenant', 'scan-parent', 'health', 'trust-decision', 'approve', 'discover-ssh', 'audit-argv']:
        parser.add_argument('--' + name)
    parser.add_argument('--remote-storage', default='~/.aidevops/wp-fleet')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--audit-read-only', action='store_true')
    parser.add_argument('--resume', action='store_true', help='Revalidate and retry the selected phase')
    return parser


def main():
    os.umask(0o077)
    args = _parser().parse_args()
    directory = private_dir(args.run_dir)
    try:
        if args.phase == 'plan':
            create_plan(args, directory)
        else:
            run_phase(args, directory)
    except Exception as error:
        atomic(directory / 'recovery.json', {'schema': SCHEMA, 'phase': args.phase,
               'status': 'stopped', 'reason': str(error) if isinstance(error, Stop) else 'operation failed',
               'recovery': 'Revalidate the same phase; changed scope needs a new approved plan'})
        raise


if __name__ == '__main__':
    try:
        main()
    except (Stop, OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile):
        print('STOP: fleet guard or operation failed; inspect private checkpoints, no rollback performed', file=sys.stderr)
        sys.exit(1)
