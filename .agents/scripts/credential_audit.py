#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Literal-only credential parsing and value-free hygiene findings. Never source shell."""
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SECRET_NAME = re.compile(r'(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|PASS|CREDENTIALS?)$')
EXPORT = re.compile(r'export ([A-Z_][A-Z0-9_]*)=(.*)')


def run(args, data=None):
    return subprocess.run(args, input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=5, check=False)


def literal(raw):
    """Keep the migration parser's deliberately conservative eligibility rules."""
    if raw.startswith('"') and raw.endswith('"'):
        return quoted_literal(raw)
    if re.fullmatch(r'[A-Za-z0-9_./:@%+,=-]+', raw):
        return raw
    return None


def quoted_literal(raw):
    if len(raw) < 2:
        return None
    raw = raw[1:-1]
    result = []
    index = 0
    while index < len(raw):
        char = raw[index]
        if char == '\\':
            index += 1
            if index == len(raw) or raw[index] not in '\\"':
                return None
            char = raw[index]
        elif char in '"$`':
            return None
        result.append(char)
        index += 1
    return ''.join(result)


def finding(path, line, name, category, **extra):
    return dict(file=str(path), line=line, name=name, category=category, **extra)


def physical_lines(original):
    # Shell terminates lines only at LF, not Python's broader Unicode separators.
    parts = original.split('\n')
    return [part + '\n' for part in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def parse(original, path):
    assignments, findings = [], []
    for index, line in enumerate(physical_lines(original)):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = EXPORT.fullmatch(line.rstrip('\n'))
        name = match[1] if match else ''
        raw = match[2] if match else ''
        category = line_category(line, match, raw)
        if category:
            findings.append(finding(path, index + 1, name, category))
        else:
            assignments.append((index, name, raw))
    return assignments, findings


def line_category(line, match, raw):
    if '\r' in line:
        return 'crlf'
    if re.search(r'export\s+[A-Z_][A-Z0-9_]*=', raw):
        return 'glued-exports'
    if not match or any(char in line for char in '\0\v\f\x1c\x1d\x1e\x85\u2028\u2029'):
        return 'unsupported-structure'
    return value_category(raw)


def value_category(raw):
    if '$' in raw or '`' in raw:
        return 'shell-expansion'
    if raw and literal(raw) is None:
        return 'inner-quote' if '"' in raw[1:-1] else 'unsupported-structure'
    return None


def read_source(path, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'r', encoding='utf-8', newline='') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
            raise ValueError('unsafe source')
        if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError('unsafe source')
        return source.read(), info


def compare(name, value, owned, helper):
    if owned is None:
        return 'backend-unavailable'
    target = 'aidevops/' + name
    if target not in owned:
        return 'not-in-gopass'
    stored = run(['gopass', 'show', '-n', target])
    if stored.returncode:
        return 'backend-unavailable'
    if stored.stdout.rstrip(b'\n') != value.encode():
        return 'drift'
    return 'prunable' if run(['bash', helper, 'check', name]).returncode == 0 else 'backend-unavailable'


def describe(record):
    return json.dumps(record, ensure_ascii=True)


def confirm(category):
    return input(f'Apply {category}? [y/N] ').strip().lower() in ('y', 'yes')


def log_fix(scripts, category, names):
    # Names only; never source content, values, or config snippets in the log.
    subprocess.run(['bash', str(scripts / 'audit-log-helper.sh'), 'log',
                    'security.event', 'security-fix ' + category + ': ' + ','.join(names)], check=True)


def migrate_outscraper(path, scripts):
    import fcntl

    # Serialize cooperating fix invocations. Other config writers may not honor
    # this lock, so retain the revision check and require the runtime be closed.
    print('Close the runtime/config editors before migrating its configuration.')
    if not confirm('Outscraper migration with runtime/config editors closed'):
        return False
    lock_path = str(path) + '.security-fix.lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('unsafe lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _migrate_outscraper_locked(path, scripts)
    finally:
        os.close(fd)


def _migrate_outscraper_locked(path, scripts):
    from lib.mcp_outscraper import register_outscraper

    original, info = read_source(path)
    if info.st_uid != os.getuid():
        return False
    config = json.loads(original)
    entry = config.get('mcp', {}).get('outscraper')
    if not isinstance(entry, dict):
        return False  # Other runtime schemas need their own launcher adaptation.
    values = [entry[key]['OUTSCRAPER_API_KEY'] for key in ('env', 'environment')
              if isinstance(entry.get(key), dict) and 'OUTSCRAPER_API_KEY' in entry[key]]
    if not values:
        return False
    stored = run(['gopass', 'show', '-n', 'aidevops/OUTSCRAPER_API_KEY'])
    if (stored.returncode or any(not isinstance(value, str) or
                                stored.stdout.rstrip(b'\n') != value.encode() for value in values)
            or run(['bash', str(scripts / 'secret-helper.sh'), 'check', 'OUTSCRAPER_API_KEY']).returncode):
        print('Retained MCP literals: store/choose the matching OUTSCRAPER_API_KEY with aidevops secret set first.')
        return False
    # Reuse the setup migration; do not build a second launcher implementation.
    register_outscraper({'mcp': config['mcp'], 'tools': config.setdefault('tools', {})})
    fd, temporary = tempfile.mkstemp(prefix='.mcp-migrate-', dir=str(Path(path).parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(config, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        current = os.stat(path, follow_symlinks=False)
        if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (
                info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size):
            raise ValueError('config changed')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def load_fix_records(scripts, helper):
    records = []
    for args in (helper + ['audit-credentials'],
                 ['bash', str(scripts / 'secret-hygiene-helper.sh'), 'audit-mcp']):
        # Each backend operation is individually bounded. The complete audit
        # can legitimately take more than one backend's five-second timeout.
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=120, check=False)
        if result.returncode:
            print('Audit unavailable; no fixes applied.', file=sys.stderr)
            return None
        records.extend(json.loads(line) for line in result.stdout.splitlines())
    return records


def fix_permissions(records, scripts):
    for record in records:
        if record['category'] != 'insecure-perms':
            continue
        # Never follow symlinks or change a foreign owner's file.
        fd = os.open(record['file'], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                continue
            os.fchmod(fd, 0o600)
        finally:
            os.close(fd)
        log_fix(scripts, 'insecure-perms', [])


def import_active(records, scripts, helper):
    active = [r for r in records if r.get('active')]
    if any(r['category'] == 'not-in-gopass' for r in active):
        if subprocess.run(helper + ['import-credentials'], check=False).returncode == 0:
            log_fix(scripts, 'import-credentials', [r['name'] for r in active if r['category'] == 'not-in-gopass'])
            refreshed = subprocess.run(helper + ['audit-credentials'], stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, timeout=120, check=True)
            active = [json.loads(line) for line in refreshed.stdout.splitlines() if json.loads(line).get('active')]
    return active


def prune_active(active, scripts, helper):
    if any(r['category'] == 'prunable' for r in active):
        if subprocess.run(helper + ['prune-plaintext', '--dry-run'], check=False).returncode == 0 and confirm('prunable'):
            if subprocess.run(helper + ['prune-plaintext'], check=False).returncode == 0:
                log_fix(scripts, 'prune-plaintext', [r['name'] for r in active if r['category'] == 'prunable'])


def trash_leftovers(records, scripts):
    leftovers = [r for r in records if r['category'] == 'leftover']
    if not leftovers or not confirm('leftover backups/temp files (move to trash)'):
        return
    backend = trash_backend()
    if backend is None:
        print('No trash backend available; backups retained.')
        return
    for record in leftovers:
        # No recursive directory removal and no permanent-deletion fallback.
        if stat.S_ISREG(os.lstat(record['file']).st_mode):
            subprocess.run(backend + [record['file']], check=True)
            log_fix(scripts, 'leftover-trashed', [])


def trash_backend():
    import shutil
    if shutil.which('trash'):
        return ['trash']
    if shutil.which('gio'):
        return ['gio', 'trash']
    return None


def fix_mcp(records, scripts):
    literals = [r for r in records if r['category'] == 'mcp-literal']
    if literals and confirm('MCP literal secret migration'):
        for path in dict.fromkeys(r['file'] for r in literals if r['server'] == 'outscraper'):
            if migrate_outscraper(path, scripts):
                log_fix(scripts, 'mcp-migrated', ['OUTSCRAPER_API_KEY'])
        print('Other MCP literals: use dataforseo-credentials.sh / outscraper-credentials.sh launch-time loaders; never embed values.')


def interactive_fix_allowed():
    markers = (os.environ.get('AIDEVOPS_HEADLESS') in ('1', 'true'),
               os.environ.get('FULL_LOOP_HEADLESS') == 'true',
               os.environ.get('WORKER_ISSUE_NUMBER'), os.environ.get('AIDEVOPS_HEADLESS_SESSION'))
    return sys.stdin.isatty() and sys.stdout.isatty() and not any(markers)


def fix(scripts):
    if not interactive_fix_allowed():
        print('security fix requires an interactive terminal; use aidevops secret audit-credentials.', file=sys.stderr)
        return 1
    helper = ['bash', str(scripts / 'secret-helper.sh')]
    records = load_fix_records(scripts, helper)
    if records is None:
        return 1
    for record in records:
        print(describe(record))
    if any(r['category'] in ('mcp-unreadable', 'unreadable-source') for r in records):
        print('Incomplete audit; unreadable sources retained and no fixes applied.', file=sys.stderr)
        return 1
    fix_permissions(records, scripts)
    active = import_active(records, scripts, helper)
    prune_active(active, scripts, helper)
    trash_leftovers(records, scripts)
    fix_mcp(records, scripts)
    print('Drift: choose explicitly with aidevops secret set NAME. Unparseable lines are unchanged.')
    print('Import/prune operate on the active store only; review other tenants separately. No provider probes performed.')
    return 0


def main():
    # Backend custody operations share these parsing primitives without a
    # module-import cycle; only CLI execution imports the backend.
    from credential_migration import audit, mcp_findings

    command, *args = sys.argv[1:]
    if command == 'audit':
        helper, loader, active, *files = args
        records = (dict(record, active=record['file'] == active) for record in audit(files, loader, helper))
    elif command == 'mcp':
        records = (record for path in args for record in mcp_findings(path))
    elif command == 'display':
        for line in sys.stdin:
            record = json.loads(line)
            # JSON quoting prevents control characters in config keys/paths becoming terminal commands.
            location = json.dumps(record['file'], ensure_ascii=True) + ':' + str(record['line'])
            detail = json.dumps({k: v for k, v in record.items() if k not in ('file', 'line')})
            print(location + '\t' + detail)
        return
    elif command == 'fix':
        try:
            sys.exit(fix(Path(args[0])))
        except (OSError, ValueError, EOFError, subprocess.SubprocessError):
            print('Security fix stopped safely; inspect the names-only audit before retrying.', file=sys.stderr)
            sys.exit(1)
    else:
        raise ValueError('unknown audit command')
    for record in records:
        print(json.dumps(record, ensure_ascii=True))


if __name__ == '__main__':
    main()
