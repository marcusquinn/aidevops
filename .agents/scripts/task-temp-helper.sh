#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Public task scratch API; sensitive-temp's private hierarchy is unchanged.
set -euo pipefail

command -v python3 >/dev/null 2>&1 || exit 1
python3 - "$PPID" "$@" <<'PY'
import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MANIFEST = '.aidevops-task-temp.json'
EXCLUDED = {'session-checkpoints', 'locks', 'pulse', 'repository-campaigns', 'README.md'}


def identity(pid):
    """Unknown is not dead; include boot identity to reject reboot/PID reuse."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return 'unknown'
    try:
        if sys.platform.startswith('linux'):
            with open(f'/proc/{pid}/stat') as source:
                fields = source.read().rsplit(')', 1)[1].split()
            if fields[0] == 'Z':
                return None
            with open('/proc/sys/kernel/random/boot_id') as source:
                return source.read().strip() + ':' + fields[19]
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='],
                                capture_output=True, text=True, check=True)
        return result.stdout.strip() or 'unknown'
    except (OSError, IndexError, subprocess.SubprocessError):
        return 'unknown'


def private_group(gid):
    """True only for the caller's own group with no other members or primary-group users."""
    try:
        import grp
        import pwd
        if gid != os.getgid() or grp.getgrgid(gid).gr_mem not in ([], [pwd.getpwuid(os.getuid()).pw_name]):
            return False
        return all(entry.pw_gid != gid or entry.pw_uid == os.getuid() for entry in pwd.getpwall())
    except (ImportError, KeyError, OSError):
        return False


def safe_root(root, create=False):
    if not root.is_absolute() or root.name != 'tmp' or str(root) == '/tmp':
        raise ValueError('scratch root must be an absolute dedicated */tmp directory')
    for part in [*reversed(root.parents), root]:
        if part.is_symlink():
            raise ValueError('symlink scratch root component')
        if part.exists():
            info = part.stat()
            if info.st_uid not in (0, os.getuid()):
                raise ValueError('foreign-owned scratch ancestor')
            if info.st_mode & 0o002 and not info.st_mode & stat.S_ISVTX:
                raise ValueError('writable scratch ancestor')
            if (info.st_mode & 0o020 and not info.st_mode & stat.S_ISVTX
                    and not (info.st_uid == os.getuid() and private_group(info.st_gid))):
                raise ValueError('writable scratch ancestor')
    if create:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.exists() and root.stat().st_uid != os.getuid():
        raise ValueError('foreign-owned scratch root')


def manifest(path):
    with open(path, opener=lambda name, flags: os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK)) as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 16384:
            raise ValueError('owner manifest must be a small regular file')
        try:
            data = json.loads(source.read(16385))
        except RecursionError:
            raise ValueError('owner manifest nesting too deep')
    if (not isinstance(data, dict) or data.get('schema') != 1
            or type(data.get('pid')) is not int or not 0 < data['pid'] <= 2**31 - 1
            or not isinstance(data.get('start'), str) or not data['start']
            or type(data.get('created')) is not int or type(data.get('expires')) is not int
            or data['expires'] < data['created']):
        raise ValueError('invalid owner manifest')
    return data


def live(data):
    current = identity(data['pid'])
    return current == 'unknown' or current == data['start']


def check_deadline(deadline):
    if time.monotonic() >= deadline:
        raise TimeoutError('cleanup work budget exhausted')


def marker_live(path):
    try:
        return live(manifest(path))
    except (OSError, ValueError, TypeError):
        return False  # Legacy leases receive age protection only.


def eligible(path, cutoff, deadline=float('inf')):
    check_deadline(deadline)
    info = path.lstat()
    if path.name in EXCLUDED or stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        return False
    managed = path.is_dir() and os.path.lexists(path / MANIFEST)
    if managed and live(manifest(path / MANIFEST)):
        return False  # Malformed manifests raise; live ownership vetoes expiry.
    if not managed and info.st_mtime >= cutoff:
        return False
    if path.name.endswith(('.lock', '.lease')) and marker_live(path):
        return False
    if path.is_dir():
        def walk_error(error):
            raise error
        for parent, dirs, files in os.walk(path, followlinks=False, onerror=walk_error):
            for name in dirs + files:
                check_deadline(deadline)
                child = os.path.join(parent, name)
                if not managed and os.lstat(child).st_mtime >= cutoff:
                    return False
                if name == MANIFEST and live(manifest(child)):
                    return False
                if name.endswith(('.lock', '.lease')) and marker_live(child):
                    return False
    return True


def size(path, deadline):
    total = path.lstat().st_blocks * 512
    if path.is_dir():
        for parent, dirs, files in os.walk(path, followlinks=False):
            for name in dirs + files:
                check_deadline(deadline)
                total += os.lstat(os.path.join(parent, name)).st_blocks * 512
    return total


def same_filesystem_trash(path):
    """Avoid moving reclaimable Linux data to Trash on the same device."""
    if not sys.platform.startswith('linux'):
        return False
    data_home = Path(os.environ.get('XDG_DATA_HOME', ''))
    if not data_home.is_absolute():
        data_home = Path.home() / '.local/share'
    trash = data_home / 'Trash'
    try:
        # Trash need not exist yet; its nearest existing ancestor owns its device.
        while not trash.exists():
            trash = trash.parent
        return path.lstat().st_dev == trash.stat().st_dev
    except OSError:
        return False  # Unknown filesystem evidence never authorises deletion.


def reject_mounted_scratch(path, deadline):
    """rmtree is symlink-safe, not mount-safe; include same-device bind mounts."""
    candidate = path.resolve()
    with open('/proc/self/mountinfo') as mounts:
        for line in mounts:
            check_deadline(deadline)
            fields = line.split()
            if len(fields) < 6:
                raise ValueError('mount evidence unavailable')
            mount = Path(re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), fields[4]))
            if mount == candidate or candidate in mount.parents:
                raise ValueError('mounted scratch retained')


def cleanup(args, root):
    safe_root(root)
    if not root.exists():
        return
    days = int(os.environ.get('AIDEVOPS_TMP_RETENTION_DAYS', '7'))
    minimum_gb = float(os.environ.get('AIDEVOPS_TMP_MIN_FREE_GB', '0'))
    minimum_percent = float(os.environ.get('AIDEVOPS_TMP_MIN_FREE_PERCENT', '10'))
    if days <= 0 or minimum_gb < 0 or not 0 <= minimum_percent <= 100:
        raise ValueError('invalid retention or pressure threshold')
    usage = shutil.disk_usage(root)
    pressure = usage.free < minimum_gb * 1024**3 or usage.free * 100 < usage.total * minimum_percent
    delete = pressure and sys.platform.startswith('linux')
    cutoff = time.time() - days * 86400
    started = time.monotonic()
    deadline = started + args.max_seconds if args.max_seconds else float('inf')
    # Reserve half the budget for reclaiming the candidates already discovered.
    scan_deadline = started + args.max_seconds / 2 if args.max_seconds else deadline
    exhausted = False
    candidates = []
    for path in root.iterdir():
        if time.monotonic() >= scan_deadline:
            exhausted = True
            break
        try:
            if eligible(path, cutoff, scan_deadline):
                candidates.append((size(path, scan_deadline) if pressure else 0, path))
        except TimeoutError:
            exhausted = True
            break
        except (OSError, ValueError, TypeError):
            continue  # Cannot prove inactivity: retain and retry next pass.
    if pressure:
        candidates.sort(key=lambda item: item[0], reverse=True)
    log_dir = Path(os.environ.get('AIDEVOPS_LOG_DIR', str(Path.home() / '.aidevops/logs')))
    log_dir.mkdir(parents=True, exist_ok=True)
    reclaimed = deleted = scanned = failed = 0
    with (log_dir / 'system-cleanup.log').open('a') as log:
        for offset in range(0, len(candidates), args.batch_size):
            if time.monotonic() >= deadline:
                exhausted = True
                break
            batch = []
            for _, path in candidates[offset:offset + args.batch_size]:
                try:
                    if eligible(path, cutoff, deadline):
                        batch.append(path)
                except TimeoutError:
                    exhausted = True
                    break
                except (OSError, ValueError, TypeError):
                    continue
            scanned += len(batch)
            if not args.force:
                for path in batch:
                    action = 'delete' if delete or same_filesystem_trash(path) else 'trash'
                    line = f'[dry-run] Would {action}: {path}'
                    print(line)
                    log.write(line + '\n')
                continue
            delete_batch = [path for path in batch if delete or same_filesystem_trash(path)]
            trash_batch = [path for path in batch if path not in delete_batch]
            if delete_batch:
                if not shutil.rmtree.avoids_symlink_attacks:
                    raise ValueError('safe recursive deletion unavailable')
                for path in delete_batch:
                    try:
                        if not eligible(path, cutoff, deadline):
                            continue
                        reject_mounted_scratch(path, deadline)
                    except TimeoutError:
                        exhausted = True
                        break
                    except (OSError, ValueError, TypeError) as error:
                        failed += 1
                        log.write(f'Retained before delete: {path}: {error}\n')
                        continue
                    try:
                        if path.is_dir() and not path.is_symlink():
                            shutil.rmtree(path)
                        else:
                            path.unlink()
                    except OSError as error:
                        failed += 1
                        log.write(f'Failed to delete: {path}: {error}\n')
                        continue  # Retain and retry next pass; keep reclaiming the rest.
                    deleted += 1
                    log.write(f'Deleted: {path}\n')
            if trash_batch:
                backends = [command for command in (['trash'], ['gio', 'trash']) if shutil.which(command[0])]
                if not backends:
                    raise ValueError('no trash backend available; entries retained')
                pending = set(trash_batch)
                # Try each backend in bulk, then isolate entries that poison a batch.
                attempts = [(backend, trash_batch) for backend in backends]
                attempts.extend((backend, [path]) for path in trash_batch for backend in backends)
                for backend, paths in attempts:
                    retry = []
                    try:
                        for path in paths:
                            if path in pending:
                                if eligible(path, cutoff, deadline):
                                    retry.append(path)
                                else:
                                    pending.discard(path)
                        check_deadline(deadline)
                    except TimeoutError:
                        exhausted = True
                        break
                    except (OSError, ValueError, TypeError):
                        continue  # Cannot prove inactivity: retain the entry.
                    if not retry:
                        continue
                    remaining = deadline - time.monotonic() if args.max_seconds else None
                    try:
                        subprocess.run([*backend, *map(str, retry)], capture_output=True, timeout=remaining)
                    except subprocess.TimeoutExpired:
                        exhausted = True
                    except OSError:
                        pass  # An unusable backend must not prevent fallback.
                    # Failed batches can still move some entries; never retry/count those twice.
                    for path in retry:
                        if not os.path.lexists(path):
                            pending.discard(path)
                            reclaimed += 1
                            log.write(f'Trashed: {path}\n')
                    if exhausted or not pending:
                        break
                failed += len(pending)
                if pending:
                    log.write(f'Failed to trash {len(pending)} entries; entries retained\n')
    print(f'[system-cleanup] mode={"force" if args.force else "dry-run"} eligible={scanned} '
          f'trashed={reclaimed} deleted={deleted} '
          f'failed={failed} pressure={int(pressure)} elapsed_s={int(time.monotonic() - started)} '
          f'budget_s={args.max_seconds} budget_exhausted={int(exhausted)}')


try:
    parent, command, *arguments = sys.argv[1:] if len(sys.argv) > 2 else [sys.argv[1], 'help']
    root = Path(os.environ.get('AIDEVOPS_TEMP_DIR', str(Path.home() / '.aidevops/.agent-workspace/tmp')))
    parser = argparse.ArgumentParser(description='Owner-bound task scratch directories')
    if command == 'create':
        parser.add_argument('task')
        parser.add_argument('--max-age', default='24h', help='positive duration: s, m, h, d (default 24h)')
        parser.add_argument('--owner-pid', type=int, default=int(parent), help='long-lived task/session process')
        args = parser.parse_args(arguments)
        duration = re.fullmatch(r'([1-9][0-9]*)([smhd]?)', args.max_age)
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,80}', args.task) or not duration or args.owner_pid <= 0:
            raise ValueError('invalid task, owner PID or duration')
        start = identity(args.owner_pid)
        if start in (None, 'unknown'):
            raise ValueError('owner process generation unavailable')
        safe_root(root, create=True)
        path = Path(tempfile.mkdtemp(prefix=f'task-{args.task}-', dir=root))
        created = int(time.time())
        seconds = int(duration[1]) * {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}[duration[2]]
        data = dict(schema=1, pid=args.owner_pid, start=start, task=args.task,
                    session=os.environ.get('AIDEVOPS_SESSION_ID', ''), created=created, expires=created + seconds)
        with (path / MANIFEST).open('x') as output:
            json.dump(data, output)
        print(path)
    elif command == 'cleanup':
        parser.add_argument('--force', action='store_true')
        parser.add_argument('--dry-run', action='store_false', dest='force')
        parser.set_defaults(force=False)
        parser.add_argument('--max-seconds', type=int, default=int(os.environ.get('AIDEVOPS_TMP_CLEANUP_MAX_SECONDS', '0')))
        parser.add_argument('--batch-size', type=int, default=int(os.environ.get('AIDEVOPS_TMP_CLEANUP_BATCH_SIZE', '200')))
        args = parser.parse_args(arguments)
        if args.max_seconds < 0 or args.batch_size <= 0:
            raise ValueError('invalid cleanup budget or batch size')
        cleanup(args, root)
    else:
        usage = ('Usage: task-temp-helper.sh create TASK [--max-age 24h] [--owner-pid PID]\n'
                 '       task-temp-helper.sh cleanup [--force|--dry-run] [--max-seconds N] [--batch-size N]')
        if command in ('help', '-h', '--help'):
            print(usage)
        else:
            print(f'[task-temp] unknown command: {command}\n{usage}', file=sys.stderr)
            sys.exit(2)
except (OSError, ValueError, TypeError) as error:
    print(f'[task-temp] {error}', file=sys.stderr)
    sys.exit(1)
PY
