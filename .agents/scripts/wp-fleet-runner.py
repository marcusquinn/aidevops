#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private fleet coordinator and bounded SSH RPC; compatible with Python 3.6.

No shell supplied by a release is executed. Remote stdout is a JSON protocol,
never a public log. Errors deliberately exclude subprocess output and paths.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

SCHEMA = 1


class Stop(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Stop(reason)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def atomic(path, value):
    path = Path(path)
    fd, name = tempfile.mkstemp(dir=str(path.parent), prefix='.checkpoint-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def command(argv, data=None, timeout=120, env=None):
    result = subprocess.run(argv, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, env=env)
    require(result.returncode == 0, 'command failed; private checkpoint retained')
    return result.stdout


def private_dir(path):
    path = Path(path)
    require(not any(p.is_symlink() for p in [path] + list(path.parents)),
            'symlink private directory refused')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(path.stat().st_uid == os.getuid(), 'private directory owner mismatch')
    require(stat.S_IMODE(path.stat().st_mode) == 0o700, 'private directory must be 0700')
    return path.resolve()


def archive(data, slug, version):
    import io
    files = {}
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        require(len(bundle.infolist()) <= 10000, 'archive member limit exceeded')
        require(sum(i.file_size for i in bundle.infolist()) <= 256 * 1024 * 1024,
                'archive expansion limit exceeded')
        for item in bundle.infolist():
            parts = item.filename.split('/')
            require(parts[0] == slug and '..' not in parts and
                    '\\' not in item.filename and not item.filename.startswith('/') and
                    stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR),
                    'unsafe archive member')
            if item.is_dir():
                continue
            require(len(parts) > 1 and all(parts), 'unsafe archive path')
            name = '/'.join(parts[1:])
            require(name not in files, 'duplicate archive member')
            content = bundle.read(item)
            files[name] = digest(content)
            if name == slug + '.php':
                header = content[:8192].decode('utf-8', 'replace')
                require(re.search(r'Plugin Name:\s*\S', header) and
                        re.search(r'Version:\s*' + re.escape(version) + r'\s*(?:\r?\n|\*/)', header),
                        'plugin header identity mismatch')
        require(slug + '.php' in files, 'expected main plugin file missing')
    return files


def wp(root, *args):
    return command(['wp', '--path=' + root] + list(args)).decode().strip()


def health(url):
    require(url.startswith(('https://', 'http://')), 'unsupported site URL')
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    try:
        response = urllib.request.build_opener(NoRedirect).open(url, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read(2 * 1024 * 1024).lower()
        require(not any(marker in body for marker in
                        (b'fatal error', b'uncaught exception', b'critical error on this website')),
                'fatal health marker detected')
        return response.code


def snapshot(request):
    root = os.path.realpath(request['root'])
    parent = os.path.realpath(request['parent'])
    require(os.path.commonpath([root, parent]) == parent and root != parent,
            'root outside approved scan parent')
    require(os.path.isfile(os.path.join(root, 'wp-config.php')), 'installation disappeared')
    slug = request['slug']
    plugin = json.loads(wp(root, 'plugin', 'get', slug, '--format=json'))
    # Detect multisite without invoking arbitrary PHP or changing configuration.
    constants = json.loads(wp(root, 'config', 'list', '--format=json'))
    multi = any(i.get('name') == 'MULTISITE' and str(i.get('value')).lower() in ('1', 'true')
                for i in constants)
    del constants
    urls = [row['url'] for row in json.loads(wp(root, 'site', 'list', '--fields=url', '--format=json'))] if multi else [wp(root, 'option', 'get', 'siteurl')]
    urls = sorted(set(urls))
    statuses = {url: json.loads(wp(root, '--url=' + url, 'plugin', 'get', slug, '--format=json'))['status'] for url in urls}
    directory = os.path.join(root, 'wp-content', 'plugins', slug)
    require(os.path.isdir(directory) and not os.path.islink(directory), 'plugin directory missing or symlinked')
    files = {}
    for current, dirs, names in os.walk(directory):
        require(not any(os.path.islink(os.path.join(current, n)) for n in dirs + names), 'plugin symlink refused')
        for name in names:
            path = os.path.join(current, name)
            with open(path, 'rb') as stream:
                files[os.path.relpath(path, directory)] = digest(stream.read())
    return {'root': root, 'urls': urls, 'version': plugin['version'],
            'host_identity': digest(encoded([os.uname().nodename, os.getuid()])),
            'activation': statuses, 'files': files,
            'health': {url: health(url) for url in urls}}


def matches(state, release):
    return state['version'] == release['version'] and state['files'] == release['files']


def version_guard(installed, target):
    # Fail closed on versions whose ordering cannot be established safely.
    require(re.fullmatch(r'\d+(?:\.\d+)*', installed) and
            re.fullmatch(r'\d+(?:\.\d+)*', target), 'numeric release versions required')
    old, new = [list(map(int, v.split('.'))) for v in (installed, target)]
    length = max(len(old), len(new))
    require(old + [0] * (length - len(old)) <= new + [0] * (length - len(new)),
            'newer installed version refused')


def check_backup(previous, run, request):
    require(previous.get('schema') == SCHEMA and previous.get('backup') and
            previous.get('fingerprint') == request['fingerprint'] and
            previous.get('baseline') == request['baseline'], 'complete matching backup required')
    for name, checksum in previous['backup'].items():
        path = run / name
        require(os.path.commonpath([str(path.resolve()), str(run)]) == str(run) and
                not path.is_symlink(), 'unsafe backup path')
        require(digest(path.read_bytes()) == checksum, 'backup checksum mismatch')


def create_backup(root, run, identity, baseline, request, checkpoint):
    """Publish only a complete backup; failed attempts own only their temporary tree."""
    backup = run / identity
    require(not backup.exists(), 'uncheckpointed backup requires operator inspection')
    temporary = Path(tempfile.mkdtemp(prefix='.backup-', dir=str(run)))
    try:
        database = temporary / 'database.sql'
        # WP-CLI handles its private mysql defaults file and its removal. Never
        # extract DB constants into this process, argv, environment or manifests.
        wp(root, 'db', 'export', str(database))
        require(database.is_file() and database.stat().st_size > 0, 'empty database backup')
        with database.open('rb') as stream:
            require(b'--' in stream.read(8192), 'database dump header missing')
        shutil.copy2(os.path.join(root, 'wp-config.php'), str(temporary / 'wp-config.php'))
        shutil.copytree(os.path.join(root, 'wp-content', 'plugins', request['slug']),
                        str(temporary / 'plugin'))
        require(snapshot(request) == request['preflight'], 'installation changed during backup')
        checksums = {}
        for current, dirs, names in os.walk(str(temporary)):
            os.chmod(current, 0o700)
            for name in names:
                path = Path(current) / name
                require(not path.is_symlink(), 'backup symlink refused')
                os.chmod(str(path), 0o600)
                checksums[str(Path(identity) / path.relative_to(temporary))] = digest(path.read_bytes())
        os.rename(str(temporary), str(backup))
        result = {'schema': SCHEMA, 'fingerprint': request['fingerprint'],
                  'backup': checksums, 'baseline': baseline}
        atomic(checkpoint, result)
        check_backup(result, run, request)
        return result
    finally:
        if temporary.exists():
            shutil.rmtree(str(temporary))


def remote(request):
    os.umask(0o077)
    require(sys.version_info >= (3, 6), 'Python 3.6 required')
    action = request['action']
    if action == 'probe':
        return {'python': True}
    if action == 'inspect':
        return snapshot(request)
    if action == 'discover':
        parent = os.path.realpath(request['parent'])
        require(os.path.isdir(parent) and parent != '/', 'explicit bounded discovery parent required')
        roots = []
        visited = 0
        for current, dirs, names in os.walk(parent, followlinks=False):
            visited += 1
            require(visited <= 10000, 'discovery directory limit exceeded')
            depth = len(Path(current).relative_to(parent).parts)
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(current, d))]
            if 'wp-config.php' in names:
                roots.append(current)
                dirs[:] = []
            elif depth >= 4:
                dirs[:] = []
        return sorted(roots)
    root = os.path.realpath(request['root'])
    storage_path = os.path.realpath(os.path.expanduser(request['storage']))
    require(os.path.commonpath([storage_path, os.path.realpath(request['parent'])]) != os.path.realpath(request['parent']),
            'storage must be outside approved scan parent')
    storage = Path(storage_path) if action in ('verify', 'check-backup') else private_dir(storage_path)
    state = snapshot(request)
    baseline = request['baseline']
    require(state['root'] == baseline['root'] and state['urls'] == baseline['urls'] and
            state['activation'] == baseline['activation'] and
            state['host_identity'] == baseline['host_identity'] and
            state['health'] == baseline['health'], 'scope, activation or health drift')
    release = request['release']
    run = storage / request['fingerprint']
    if action not in ('verify', 'check-backup'):
        run = private_dir(run)
    identity = digest(root.encode())
    checkpoint = run / (identity + '.json')
    previous = json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
    require(not previous or previous.get('schema') == SCHEMA, 'unsupported checkpoint schema')
    if action == 'check-backup':
        check_backup(previous, run, request)
        return {'backup_verified': True}
    if action == 'verify':
        require(matches(state, release), 'installed release bytes mismatch')
        require(state['health'] == baseline['health'], 'health expectation mismatch')
        audit = request.get('audit_argv')
        if audit:
            require(isinstance(audit, list) and all(isinstance(a, str) for a in audit), 'invalid read-only audit argv')
            require(not any(a.startswith(('--path', '--url', '--ssh', '--http', '--exec', '--require'))
                            for a in audit), 'audit transport/bootstrap overrides refused')
            for url in baseline['urls']:
                wp(root, '--url=' + url, *audit)
        return {'verified': True, 'state': state}
    # Fixed per-account namespace, independent of run ID AND backup storage.
    locks = private_dir(os.path.expanduser('~/.aidevops/wp-fleet-locks'))
    lock = locks / (identity + '.lock')
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise Stop('installation locked; no stale-lock takeover permitted')
    token = digest(os.urandom(32))
    atomic(lock / 'owner.json', {'token': token})
    try:
        # Recheck after acquiring the cooperative lock.
        state = snapshot(request)
        require(state == request['preflight'], 'installation changed after fleet preflight')
        if action == 'backup':
            require(state == baseline or matches(state, release), 'backup baseline drift')
            if previous.get('backup'):
                check_backup(previous, run, request)
                return previous
            return create_backup(root, run, identity, baseline, request, checkpoint)
        require(action == 'deploy', 'unknown remote phase')
        check_backup(previous, run, request)
        version_guard(state['version'], release['version'])
        if matches(state, release):
            return {'skipped': True, 'state': state}
        require(state['version'] == baseline['version'] and state['files'] == baseline['files'],
                'installed version or bytes drift; refusing overwrite')
        artifact = base64.b64decode(request['artifact'])
        require(digest(artifact) == release['sha256'], 'artifact checksum mismatch')
        require(archive(artifact, request['slug'], release['version']) == release['files'], 'archive identity mismatch')
        staged = run / 'release.zip'
        if staged.exists():
            require(digest(staged.read_bytes()) == release['sha256'], 'staged artifact mismatch')
        else:
            fd = os.open(str(staged), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(artifact)
        previous['mutation_started'] = True
        atomic(checkpoint, previous)
        wp(root, 'plugin', 'install', str(staged), '--force')
        after = snapshot(request)
        require(matches(after, release) and after['activation'] == baseline['activation'] and
                after['health'] == baseline['health'], 'post-deploy verification failed; no automatic rollback')
        previous['deployed'] = True
        atomic(checkpoint, previous)
        return {'deployed': True, 'state': after}
    finally:
        owner = json.loads((lock / 'owner.json').read_text())
        if owner.get('token') == token:
            (lock / 'owner.json').unlink()
            lock.rmdir()


def transport(site, request):
    host = site['ssh_host']
    require(isinstance(host, str) and not host.startswith('-') and
            re.fullmatch(r'[A-Za-z0-9_.-]+', host), 'invalid SSH alias')
    argv = ['ssh', '-o', 'ConnectTimeout=20']
    env = dict(os.environ)
    reference = site.get('ssh_password_env')
    if reference:
        require(env.get(reference), 'shared SSH credential unavailable')
        env['SSHPASS'] = env[reference]
        argv = ['sshpass', '-e'] + argv
    else:
        argv += ['-o', 'BatchMode=yes']
    for key, flag in [('ssh_user', '-l'), ('ssh_port', '-p'), ('ssh_identity_file', '-i')]:
        if site.get(key):
            argv += [flag, str(site[key])]
    source = Path(__file__).read_bytes()
    launcher = "import sys,json;exec(compile(%r,'fleet','exec'));" % source
    # __name__ is changed so the CLI entry point is not executed remotely.
    launcher = "__name__='fleet_rpc';" + launcher + "print(json.dumps(remote(json.load(sys.stdin))))"
    argv += [host, 'python3 -c ' + shlex.quote(launcher)]
    result = command(argv, encoded(request), timeout=600, env=env)
    return json.loads(result)


def inventory(args):
    if args.discover_ssh:
        require(args.scan_parent and not args.sites and not args.category, 'discovery requires exclusive explicit SSH selection')
        site = {'ssh_host': args.discover_ssh}
        roots = transport(site, {'action': 'discover', 'parent': args.scan_parent})
        require(roots, 'discovery found no installations')
        return [dict(site, id=str(n), wp_path=root) for n, root in enumerate(roots)]
    argv = ['bash', str(Path(__file__).with_name('wp-helper.sh'))]
    if args.tenant:
        argv += ['--tenant', args.tenant]
    argv += ['--export-sites']
    sites = [json.loads(line) for line in command(argv).decode().splitlines()]
    selected = [s for s in sites if (args.sites and s['id'] in args.sites.split(',')) or
                (args.category and s.get('category') == args.category)]
    require(selected, 'explicit nonempty site selection required')
    if args.sites:
        require(set(args.sites.split(',')) <= {s['id'] for s in selected}, 'selected site missing')
    return selected


def fingerprint(manifest):
    return digest(encoded({k: manifest[k] for k in ('schema', 'release', 'installations', 'selection', 'inventory', 'aliases')}))


def release_check(release):
    repo, tag = release['repository'], release['tag']
    data = json.loads(command(['gh', 'api', 'repos/' + repo + '/releases/tags/' + tag]))
    require(not data['draft'] and data['id'] == release['release_id'], 'published release identity changed')
    assets = [a for a in data['assets'] if a['name'] == release['asset']]
    require(len(assets) == 1 and assets[0]['id'] == release['asset_id'] and
            assets[0].get('digest') == 'sha256:' + release['sha256'], 'trusted asset digest mismatch')
    ref = json.loads(command(['gh', 'api', 'repos/' + repo + '/git/ref/tags/' + tag]))['object']
    require(ref['type'] == 'tag' and ref['sha'] == release['tag_object'], 'annotated tag changed')
    annotated = json.loads(command(['gh', 'api', 'repos/' + repo + '/git/tags/' + ref['sha']]))
    require(annotated['object']['sha'] == release['commit'] and annotated['object']['type'] == 'commit', 'tag commit changed')
    verification = annotated['verification']
    require(verification == release['signature'] and (verification['verified'] or release.get('trust_decision')),
            'tag signature unverified; explicit trust decision required')
    runs = json.loads(command(['gh', 'api', 'repos/' + repo + '/actions/runs?head_sha=' + release['commit'] + '&per_page=100']))['workflow_runs']
    require(runs and all(r['status'] == 'completed' and r['conclusion'] == 'success' for r in runs),
            'successful exact-commit CI required')


def create_plan(args, directory):
    require(args.slug and re.fullmatch(r'[a-z0-9-]+', args.slug), 'explicit plugin slug required')
    require(args.repository and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository), 'explicit repository required')
    require(args.tag and args.asset and args.version and args.sha256 and args.scan_parent,
            'release identity, trusted checksum and scan parent required')
    require(re.fullmatch(r'[a-f0-9]{64}', args.sha256), 'invalid trusted checksum')
    require(not (directory / 'manifest.json').exists(), 'run already exists; use phase/resume')
    data = json.loads(command(['gh', 'api', 'repos/' + args.repository + '/releases/tags/' + args.tag]))
    assets = [a for a in data['assets'] if a['name'] == args.asset]
    require(len(assets) == 1, 'published asset missing or ambiguous')
    ref = json.loads(command(['gh', 'api', 'repos/' + args.repository + '/git/ref/tags/' + args.tag]))['object']
    require(ref['type'] == 'tag', 'signed annotated tag required')
    tag = json.loads(command(['gh', 'api', 'repos/' + args.repository + '/git/tags/' + ref['sha']]))
    release = {'repository': args.repository, 'tag': args.tag, 'asset': args.asset,
               'version': args.version, 'sha256': args.sha256, 'release_id': data['id'],
               'asset_id': assets[0]['id'], 'tag_object': ref['sha'], 'commit': tag['object']['sha'],
               'signature': tag['verification'], 'trust_decision': args.trust_decision}
    release_check(release)
    artifact = command(['gh', 'api', 'repos/' + args.repository + '/releases/assets/' + str(assets[0]['id']),
                        '-H', 'Accept: application/octet-stream'])
    require(digest(artifact) == args.sha256, 'downloaded checksum mismatch')
    release['files'] = archive(artifact, args.slug, args.version)
    selection = {'sites': args.sites, 'category': args.category, 'tenant': args.tenant,
                 'scan_parent': args.scan_parent, 'slug': args.slug, 'storage': args.remote_storage,
                 'discover_ssh': args.discover_ssh, 'audit_argv': json.loads(args.audit_argv) if args.audit_argv else None}
    require(not selection['audit_argv'] or args.audit_read_only, 'operator read-only audit attestation required')
    selected = inventory(args)
    manifest = {'schema': SCHEMA, 'release': release, 'selection': selection,
                'installations': [], 'inventory': selected, 'aliases': []}
    expectations = json.loads(Path(args.health).read_text()) if args.health else {}
    seen = set()
    for site in selected:
        transport(site, {'action': 'probe'})  # detect Python before any staging
        request = {'action': 'inspect', 'root': site['wp_path'], 'parent': args.scan_parent, 'slug': args.slug}
        state = transport(site, request)
        version_guard(state['version'], args.version)
        require(all(code == expectations.get(url, 200) for url, code in state['health'].items()),
                'baseline health requires per-URL explicit expectation')
        manifest['aliases'].append({'site': site, 'baseline': state, 'request': request})
        identity = (state['host_identity'], state['root'])
        if identity in seen:
            continue
        seen.add(identity)
        manifest['installations'].append({'site': site, 'baseline': state, 'request': request})
    manifest['fingerprint'] = fingerprint(manifest)
    fd = os.open(str(directory / 'release.zip'), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(artifact)
    atomic(directory / 'manifest.json', manifest)
    print('Plan sealed: ' + manifest['fingerprint'])


def run_phase(args, directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    require(manifest.get('schema') == SCHEMA, 'unsupported manifest schema')
    require(manifest['fingerprint'] == fingerprint(manifest), 'plan fingerprint mismatch')
    if args.phase == 'report':
        evidence = json.loads((directory / 'evidence.json').read_text()) if (directory / 'evidence.json').exists() else {}
        print(json.dumps({'schema': SCHEMA, 'installations': len(manifest['installations']),
                          'completed': len(evidence.get('completed', [])), 'phase': evidence.get('phase', 'plan'),
                          'status': evidence.get('status', 'planned')}))
        return
    if args.phase == 'deploy':
        require(args.apply and args.approve == manifest['fingerprint'], 'exact fingerprint and --apply required')
    release_check(manifest['release'])
    artifact = (directory / 'release.zip').read_bytes()
    require(digest(artifact) == manifest['release']['sha256'], 'private artifact checksum mismatch')
    require(archive(artifact, manifest['selection']['slug'], manifest['release']['version']) == manifest['release']['files'], 'archive changed')
    selection = manifest['selection']
    current_args = argparse.Namespace(**selection)
    current = inventory(current_args)
    # Every selected alias remains in the registry, including deduplicated aliases.
    planned_sites = manifest.get('inventory')
    require(planned_sites == current, 'inventory drift; new plan approval required')
    states = []
    for installation in manifest['aliases']:
        state = transport(installation['site'], installation['request'])
        baseline = installation['baseline']
        require(state['root'] == baseline['root'] and state['urls'] == baseline['urls'] and
                state['activation'] == baseline['activation'] and state['health'] == baseline['health'], 'fleet scope/health/activation drift')
        require(state == baseline or matches(state, manifest['release']), 'fleet version/bytes drift')
        require(state['host_identity'] == baseline['host_identity'], 'alias host identity drift')
    for installation in manifest['installations']:
        state = transport(installation['site'], installation['request'])
        states.append(state)
        if args.phase == 'deploy':
            transport(installation['site'], dict(installation['request'], action='check-backup',
                      baseline=installation['baseline'], release=manifest['release'],
                      fingerprint=manifest['fingerprint'], storage=selection['storage']))
    if (directory / 'evidence.json').exists():
        # Keep historical completed-site evidence even if a later phase fails.
        old = json.loads((directory / 'evidence.json').read_text())
        atomic(directory / ('evidence-' + digest(encoded(old)) + '.json'), old)
    evidence = {'schema': SCHEMA, 'phase': args.phase, 'status': 'running', 'completed': []}
    atomic(directory / 'evidence.json', evidence)
    try:
        for installation, state in zip(manifest['installations'], states):
            request = dict(installation['request'], action=args.phase, baseline=installation['baseline'],
                           release=manifest['release'], fingerprint=manifest['fingerprint'],
                           storage=selection['storage'], preflight=state, audit_argv=selection['audit_argv'])
            if args.phase == 'deploy':
                request['artifact'] = base64.b64encode(artifact).decode()
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
    print('Phase complete: ' + args.phase)


def main():
    os.umask(0o077)
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
    args = parser.parse_args()
    directory = private_dir(args.run_dir)
    try:
        if args.phase == 'plan':
            create_plan(args, directory)
        else:
            run_phase(args, directory)
    except Exception:
        atomic(directory / 'recovery.json', {'schema': SCHEMA, 'phase': args.phase,
               'status': 'stopped', 'recovery': 'Revalidate the same phase; changed scope needs a new approved plan'})
        raise


if __name__ == '__main__':
    try:
        main()
    except (Stop, OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile):
        print('STOP: fleet guard or operation failed; inspect private checkpoints, no rollback performed', file=sys.stderr)
        sys.exit(1)
