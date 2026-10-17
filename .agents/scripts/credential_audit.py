#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Literal-only credential parsing and value-free hygiene findings. Never source shell."""
import json
import os
import stat
import sys
from pathlib import Path
from subprocess import SubprocessError  # nosec B404

from credential_findings import audit
from credential_mcp import mcp_findings, migrate_outscraper
from credential_process import run, trash_backend


def describe(record):
    return json.dumps(record, ensure_ascii=True)


def confirm(category):
    return input(f'Apply {category}? [y/N] ').strip().lower() in ('y', 'yes')


def log_fix(scripts, category, names):
    # Names only; never source content, values, or config snippets in the log.
    run(['bash', str(scripts / 'audit-log-helper.sh'), 'log',
         'security.event', 'security-fix ' + category + ': ' + ','.join(names)],
        check=True, capture=False, timeout=30)


def load_fix_records(scripts, helper):
    records = []
    for args in (helper + ['audit-credentials'],
                 ['bash', str(scripts / 'secret-hygiene-helper.sh'), 'audit-mcp']):
        # Each backend operation is individually bounded. The complete audit
        # can legitimately take more than one backend's five-second timeout.
        result = run(args, timeout=120)
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
        if run(helper + ['import-credentials'], capture=False, timeout=120).returncode == 0:
            log_fix(scripts, 'import-credentials', [r['name'] for r in active if r['category'] == 'not-in-gopass'])
            refreshed = run(helper + ['audit-credentials'], timeout=120, check=True)
            active = [json.loads(line) for line in refreshed.stdout.splitlines() if json.loads(line).get('active')]
    return active


def prune_active(active, scripts, helper):
    if any(r['category'] == 'prunable' for r in active):
        if run(helper + ['prune-plaintext', '--dry-run'], capture=False, timeout=120).returncode == 0 and confirm('prunable'):
            if run(helper + ['prune-plaintext'], capture=False, timeout=120).returncode == 0:
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
            run(backend + [record['file']], check=True, capture=False, timeout=30)
            log_fix(scripts, 'leftover-trashed', [])


def fix_mcp(records, scripts):
    literals = [r for r in records if r['category'] == 'mcp-literal']
    if literals and confirm('MCP literal secret migration'):
        for path in dict.fromkeys(r['file'] for r in literals if r['server'] == 'outscraper'):
            if migrate_outscraper(path, scripts, confirm):
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
        except (OSError, ValueError, EOFError, SubprocessError):
            print('Security fix stopped safely; inspect the names-only audit before retrying.', file=sys.stderr)
            sys.exit(1)
    else:
        raise ValueError('unknown audit command')
    for record in records:
        print(json.dumps(record, ensure_ascii=True))


if __name__ == '__main__':
    main()
