#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Remote-side WordPress fleet phases, executed over SSH by wp-fleet-runner.py.

Python 3.6 compatible; standard library plus wp_fleet_guards only. Remote
stdout is the JSON protocol, never a public log.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import urllib.error
import urllib.request

from wp_fleet_guards import (SCHEMA, Stop, archive, atomic, audit_guard, command, digest, encoded,
                             matches, private_dir, require, scope_guard, version_guard)

FATAL_MARKERS = (b'fatal error', b'uncaught exception', b'critical error on this website')
READ_ONLY_PHASES = ('verify', 'check-backup')
LOCK_DIR = '~/.aidevops/wp-fleet-locks'
DISCOVERY_DEPTH = 4
DISCOVERY_LIMIT = 10000


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def wp(root, *args):
    return command(['wp', '--path=' + root] + list(args)).decode().strip()


def health(url):
    require(url.startswith(('https://', 'http://')), 'unsupported site URL')
    try:
        response = urllib.request.build_opener(_NoRedirect).open(url, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read(2 * 1024 * 1024).lower()
        require(not any(marker in body for marker in FATAL_MARKERS), 'fatal health marker detected')
        return response.code


def _scoped_root(request):
    root = os.path.realpath(request['root'])
    parent = os.path.realpath(request['parent'])
    require(root != parent and os.path.commonpath([root, parent]) == parent,
            'root outside approved scan parent')
    return root


def _site_urls(root):
    # Detect multisite without invoking arbitrary PHP or changing configuration.
    constants = json.loads(wp(root, 'config', 'list', '--format=json'))
    multisite = any(item.get('name') == 'MULTISITE' and str(item.get('value')).lower() in ('1', 'true')
                    for item in constants)
    if not multisite:
        return [wp(root, 'option', 'get', 'siteurl')]
    sites = json.loads(wp(root, 'site', 'list', '--fields=url', '--format=json'))
    return sorted({row['url'] for row in sites})


def _plugin_files(root, slug):
    directory = os.path.join(root, 'wp-content', 'plugins', slug)
    layout = 'custom or symlinked plugin layout unsupported'
    require(wp(root, 'plugin', 'path', slug, '--dir') == directory, layout)
    require(os.path.isdir(directory) and os.path.realpath(directory) == directory, layout)
    files = {}
    for current, dirs, names in os.walk(directory):
        require(not any(os.path.islink(os.path.join(current, n)) for n in dirs + names), 'plugin symlink refused')
        for name in names:
            path = os.path.join(current, name)
            with open(path, 'rb') as stream:
                files[os.path.relpath(path, directory)] = digest(stream.read())
    return files


def snapshot(request):
    root = _scoped_root(request)
    config = Path(root) / 'wp-config.php'
    require(config.is_file() and not config.is_symlink(), 'installation disappeared or config symlinked')
    slug = request['slug']
    plugin = json.loads(wp(root, 'plugin', 'get', slug, '--format=json'))
    urls = _site_urls(root)
    activation = {url: json.loads(wp(root, '--url=' + url, 'plugin', 'get', slug, '--format=json'))['status']
                  for url in urls}
    return {'root': root, 'urls': urls, 'version': plugin['version'],
            'host_identity': digest(encoded([os.uname().nodename, os.getuid()])),
            'config_sha256': digest(config.read_bytes()),
            'activation': activation, 'files': _plugin_files(root, slug),
            'health': {url: health(url) for url in urls}}


def _expected_backup(request):
    """Map every required backup file to its checksum (None: dump, checked on disk only)."""
    baseline = request['baseline']
    identity = digest(baseline['root'].encode())
    expected = {identity + '/database.sql': None, identity + '/wp-config.php': baseline['config_sha256']}
    for name, checksum in baseline['files'].items():
        expected[identity + '/plugin/' + name] = checksum
    return expected


def _verify_backup_file(run, name, checksum):
    path = run / name
    unsafe = 'unsafe backup path or permissions'
    require(os.path.commonpath([str(path.resolve()), str(run)]) == str(run), unsafe)
    require(not any(p.is_symlink() for p in [path] + list(path.parents)), unsafe)
    require(path.is_file() and stat.S_IMODE(path.stat().st_mode) == 0o600, unsafe)
    require(digest(path.read_bytes()) == checksum, 'backup checksum mismatch')


def check_backup(previous, run, request):
    required = 'complete matching backup required'
    require(previous.get('schema') == SCHEMA and previous.get('backup'), required)
    require(previous.get('fingerprint') == request['fingerprint'], required)
    require(previous.get('baseline') == request['baseline'], required)
    backup = previous['backup']
    expected = _expected_backup(request)
    require(set(backup) == set(expected), 'incomplete backup file set')
    require(all(checksum is None or backup[name] == checksum for name, checksum in expected.items()),
            'backup config or plugin identity mismatch')
    for name, checksum in backup.items():
        _verify_backup_file(run, name, checksum)


def _copy_backup_sources(root, temporary, slug):
    database = temporary / 'database.sql'
    # WP-CLI handles its private mysql defaults file and its removal. Never
    # extract DB constants into this process, argv, environment or manifests.
    wp(root, 'db', 'export', str(database))
    require(database.is_file() and database.stat().st_size > 0, 'empty database backup')
    with database.open('rb') as stream:
        require(b'--' in stream.read(8192), 'database dump header missing')
    shutil.copy2(os.path.join(root, 'wp-config.php'), str(temporary / 'wp-config.php'))
    shutil.copytree(os.path.join(root, 'wp-content', 'plugins', slug), str(temporary / 'plugin'))


def _seal_tree(temporary, identity):
    checksums = {}
    for current, _dirs, names in os.walk(str(temporary)):
        os.chmod(current, 0o700)
        for name in names:
            path = Path(current) / name
            require(not path.is_symlink(), 'backup symlink refused')
            os.chmod(str(path), 0o600)
            checksums[str(Path(identity) / path.relative_to(temporary))] = digest(path.read_bytes())
    return checksums


def create_backup(request, context):
    """Publish only a complete backup; failed attempts own only their temporary tree."""
    run, identity = context['run'], context['identity']
    require(not (run / identity).exists(), 'uncheckpointed backup requires operator inspection')
    temporary = Path(tempfile.mkdtemp(prefix='.backup-', dir=str(run)))
    try:
        _copy_backup_sources(context['root'], temporary, request['slug'])
        require(snapshot(request) == request['preflight'], 'installation changed during backup')
        checksums = _seal_tree(temporary, identity)
        os.rename(str(temporary), str(run / identity))
        result = {'schema': SCHEMA, 'fingerprint': request['fingerprint'],
                  'backup': checksums, 'baseline': request['baseline']}
        atomic(context['checkpoint'], result)
        check_backup(result, run, request)
        return result
    finally:
        if temporary.exists():
            shutil.rmtree(str(temporary))


def discover(request):
    parent = os.path.realpath(request['parent'])
    require(os.path.isdir(parent) and parent != '/', 'explicit bounded discovery parent required')
    roots = []
    for visited, (current, dirs, names) in enumerate(os.walk(parent, followlinks=False), 1):
        require(visited <= DISCOVERY_LIMIT, 'discovery directory limit exceeded')
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(current, d))]
        if 'wp-config.php' in names:
            roots.append(current)
            dirs[:] = []
        elif len(Path(current).relative_to(parent).parts) >= DISCOVERY_DEPTH:
            dirs[:] = []
    return sorted(roots)


def _storage(request):
    storage_input = Path(os.path.expanduser(request['storage']))
    private = 'absolute nonsymlink private storage required'
    require(storage_input.is_absolute(), private)
    require(not any(p.is_symlink() for p in [storage_input] + list(storage_input.parents)), private)
    storage_path = os.path.realpath(str(storage_input))
    parent = os.path.realpath(request['parent'])
    require(os.path.commonpath([storage_path, parent]) != parent, 'storage must be outside approved scan parent')
    if request['action'] in READ_ONLY_PHASES:
        return Path(storage_path)
    return private_dir(storage_path)


def remote_context(request):
    root = os.path.realpath(request['root'])
    storage = _storage(request)
    state = snapshot(request)
    scope_guard(state, request['baseline'], request['release'])
    run = storage / request['fingerprint']
    if request['action'] not in READ_ONLY_PHASES:
        run = private_dir(run)
    identity = digest(root.encode())
    checkpoint = run / (identity + '.json')
    previous = json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
    require(not previous or previous.get('schema') == SCHEMA, 'unsupported checkpoint schema')
    return {'root': root, 'state': state, 'run': run, 'identity': identity,
            'checkpoint': checkpoint, 'previous': previous}


def remote_verify(request, context):
    state = context['state']
    require(matches(state, request['release']), 'installed release bytes mismatch')
    audit = request.get('audit_argv')
    if audit:
        audit_guard(audit)
        for url in request['baseline']['urls']:
            wp(context['root'], '--url=' + url, *audit)
    return {'verified': True, 'state': state}


def _acquire_lock(identity):
    # Fixed per-account namespace, independent of run ID and backup storage.
    lock = private_dir(os.path.expanduser(LOCK_DIR)) / (identity + '.lock')
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise Stop('installation locked; no stale-lock takeover permitted')
    owner = os.urandom(16).hex()
    atomic(lock / 'owner.json', {'token': owner})
    return lock, owner


def _release_lock(lock, owner):
    recorded = json.loads((lock / 'owner.json').read_text())
    if recorded.get('token') == owner:
        (lock / 'owner.json').unlink()
        lock.rmdir()


def _backup_phase(request, context, state):
    baseline = request['baseline']
    require(state == baseline or matches(state, request['release']), 'backup baseline drift')
    previous = context['previous']
    if previous.get('backup'):
        check_backup(previous, context['run'], request)
        return previous
    require(state == baseline, 'original baseline backup required before deployment')
    return create_backup(request, context)


def remote_write(request, context):
    lock, owner = _acquire_lock(context['identity'])
    try:
        # Recheck after acquiring the cooperative lock.
        state = snapshot(request)
        require(state == request['preflight'], 'installation changed after fleet preflight')
        if request['action'] == 'backup':
            return _backup_phase(request, context, state)
        return remote_deploy(request, context, state)
    finally:
        _release_lock(lock, owner)


def _stage_artifact(request, run):
    release = request['release']
    artifact = base64.b64decode(request['artifact'])
    require(digest(artifact) == release['sha256'], 'artifact checksum mismatch')
    require(archive(artifact, request['slug'], release['version']) == release['files'], 'archive identity mismatch')
    staged = run / 'release.zip'
    require(not staged.is_symlink(), 'staged artifact symlink refused')
    if staged.exists():
        require(digest(staged.read_bytes()) == release['sha256'], 'staged artifact mismatch')
        return staged
    fd = os.open(str(staged), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(artifact)
    return staged


def remote_deploy(request, context, state):
    previous = context['previous']
    baseline, release = request['baseline'], request['release']
    check_backup(previous, context['run'], request)
    version_guard(state['version'], release['version'])
    if matches(state, release):
        return {'skipped': True, 'state': state}
    require(state['version'] == baseline['version'] and state['files'] == baseline['files'],
            'installed version or bytes drift; refusing overwrite')
    staged = _stage_artifact(request, context['run'])
    previous['mutation_started'] = True
    atomic(context['checkpoint'], previous)
    wp(context['root'], 'plugin', 'install', str(staged), '--force')
    after = snapshot(request)
    scope_guard(after, baseline, release)
    require(matches(after, release), 'post-deploy verification failed; no automatic rollback')
    previous['deployed'] = True
    atomic(context['checkpoint'], previous)
    return {'deployed': True, 'state': after}


def _check_backup_phase(request, context):
    check_backup(context['previous'], context['run'], request)
    return {'backup_verified': True}


def _probe(_request):
    return {'python': True}


DIRECT_PHASES = {'probe': _probe, 'inspect': snapshot, 'discover': discover}
CONTEXT_PHASES = {'check-backup': _check_backup_phase, 'verify': remote_verify,
                  'backup': remote_write, 'deploy': remote_write}


def remote(request):
    os.umask(0o077)
    require(sys.version_info >= (3, 6), 'Python 3.6 required')
    action = request['action']
    if action in DIRECT_PHASES:
        return DIRECT_PHASES[action](request)
    require(action in CONTEXT_PHASES, 'unknown remote phase')
    return CONTEXT_PHASES[action](request, remote_context(request))
