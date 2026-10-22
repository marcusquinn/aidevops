#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Reclaim only ignored, regenerable output in idle linked worktrees.
# Usage: worktree-artefact-reclaim.sh [--force] [--max-seconds N] [--idle-days N]
# Defaults: dry run, 60 seconds, AIDEVOPS_WORKTREE_IDLE_DAYS (14).
# .hermit itself contains project configuration; only its cache(s) qualify.
# No permanent-delete fallback: without a native cleaner/trash, retain output.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Internal subprocess boundary: the Python coordinator applies the same deadline
# to guard probes as to Git, sizing, and cleaners. Unknown evidence vetoes work.
_artefact_guard() {
	local wt_path="$1"
	local branch="$2"
	local snapshot="" owner_pid="" status=0
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
	# shellcheck source=audit-worktree-removal-helper.sh
	source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
	worktree_removal_guard "$wt_path" "worktree-artefact-reclaim.sh" "idle-artefacts" || return 1
	if snapshot=$(check_worktree_owner_snapshot "$wt_path"); then
		IFS='|' read -r owner_pid _ <<<"$snapshot"
		# Conservatively retain stale claims too; the registry owner clears them.
		[[ -z "$owner_pid" ]] || return 1
	else
		status=$?
		[[ "$status" -eq 1 ]] || return 1
	fi
	if [[ -n "$branch" ]]; then
		if bash "${SCRIPT_DIR}/interactive-session-helper.sh" branch-has-active-claim "$branch" --worktree "$wt_path" >/dev/null 2>&1; then
			return 1
		else
			status=$?
			[[ "$status" -eq 1 ]] || return 1
		fi
	fi
	return 0
}

if [[ "${1:-}" == "--check-worktree" ]]; then
	CHECK_WT_PATH="${2:-}"
	CHECK_WT_BRANCH="${3:-}"
	_artefact_guard "$CHECK_WT_PATH" "$CHECK_WT_BRANCH"
	exit $?
fi

python3 - "$SCRIPT_DIR/worktree-artefact-reclaim.sh" "$@" <<'PY'
import argparse
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description='Reclaim ignored output in idle linked worktrees (dry run by default)')
parser.add_argument('--force', action='store_true')
parser.add_argument('--max-seconds', type=int, default=60)
parser.add_argument('--idle-days', type=int, default=os.environ.get('AIDEVOPS_WORKTREE_IDLE_DAYS', '14'))
helper = sys.argv[1]
args = parser.parse_args(sys.argv[2:])
if args.max_seconds < 1 or args.idle_days < 1:
    parser.error('budgets and idle days must be positive integers')
deadline = time.monotonic() + args.max_seconds
cutoff = time.time() - args.idle_days * 86400
base = Path(os.environ.get('AIDEVOPS_WORKTREE_BASE_DIR', str(Path.home() / 'Git/_worktrees'))).expanduser()


def remaining():
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError('budget exhausted')
    return seconds


def run(argv):
    timeout = remaining()
    # A guard/cleaner can spawn helpers that inherit its pipes. Kill the whole
    # group on timeout, rather than blocking forever draining orphaned pipes.
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=1)
        raise
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def git(wt, *argv):
    result = run(['git', '-C', str(wt), *argv])
    if result.returncode:
        raise ValueError('Git evidence unavailable')
    return result.stdout


def safe_candidate(wt, path):
    remaining()
    if path.is_symlink() or not path.is_dir() or path.is_mount() or path.resolve() != path:
        return False
    if os.path.lexists(path / '.git'):
        return False
    relative = path.relative_to(wt).as_posix() + '/'
    if run(['git', '-C', str(wt), 'check-ignore', '-q', '--', relative]).returncode != 0:
        return False
    # An ignored directory can still contain tracked files or negated exceptions.
    if git(wt, 'ls-files', '-z', '--', relative):
        return False
    if git(wt, 'ls-files', '--others', '--exclude-standard', '-z', '--', relative):
        return False
    # Only output beside project sources: an ignored directory nested inside
    # untracked, unignored output (for example a packaged .app) is retained.
    if path.parent != wt and not git(wt, 'ls-files', '-z', '--', path.parent.relative_to(wt).as_posix() + '/'):
        return False
    return True


def walk(root):
    # Do not follow symlinks, cross mounts, or enter nested repositories.
    if os.path.lexists(root / '.git'):
        raise ValueError('nested repository')
    stack = [root]
    while stack:
        remaining()
        parent = stack.pop()
        with os.scandir(parent) as entries:
            for entry in entries:
                remaining()
                path = Path(entry.path)
                yield path, entry
                if entry.is_dir(follow_symlinks=False):
                    if path.is_mount() or os.path.lexists(path / '.git'):
                        raise ValueError('nested repository or mount')
                    stack.append(path)


def allowlisted(path):
    name = path.name
    if name in {'node_modules', '.next', '.turbo', 'dist', 'build'}:
        return True
    if name == 'target':
        return (path.parent / 'Cargo.toml').is_file()
    return path.parent.name == '.hermit' and name in {'cache', 'caches'}


def ignored_directories(wt):
    # Git reports only the top-most ignored directory of each ignored tree, so
    # package-internal names (for example vendor/pkg/build) are never selected
    # and an ignored dependency tree is never partially removed.
    output = git(wt, 'ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z')
    for raw in output.split(b'\0'):
        relative = os.fsdecode(raw)
        if relative.endswith('/') and '/.git/' not in '/' + relative:
            yield wt / relative.rstrip('/')


def last_reflog_time(private_git_dir):
    # Maintenance (reflog expiry, gc, recovery tooling) rewrites logs/HEAD, so
    # its mtime is not activity; the newest entry's own timestamp is.
    reflog = private_git_dir / 'logs' / 'HEAD'
    if not reflog.is_file():
        return 0
    with reflog.open('rb') as handle:
        handle.seek(0, os.SEEK_END)
        handle.seek(max(0, handle.tell() - 65536))
        lines = [line for line in handle.read().splitlines() if line.strip()]
    if not lines:
        return 0  # Expired/empty reflog: HEAD's own mtime remains the signal.
    for line in reversed(lines):
        identity = line.split(b'\t', 1)[0].split()
        if len(identity) >= 2 and identity[-2].isdigit():
            return int(identity[-2])
    raise ValueError('unreadable HEAD reflog')


def idle_candidates(wt, private_git_dir):
    # Commits and checkouts write HEAD and append to its reflog. The index is
    # not used: read-only `git status` probes may refresh it opportunistically.
    head = private_git_dir / 'HEAD'
    if head.stat().st_mtime >= cutoff or last_reflog_time(private_git_dir) >= cutoff:
        raise ValueError('recent Git activity')
    candidates = sorted(path for path in ignored_directories(wt) if allowlisted(path) and safe_candidate(wt, path))
    skip = set(candidates)
    stack = [wt]
    while stack:
        remaining()
        parent = stack.pop()
        with os.scandir(parent) as entries:
            for entry in entries:
                remaining()
                path = Path(entry.path)
                if (parent == wt and entry.name == '.git') or path in skip:
                    continue
                if entry.is_dir(follow_symlinks=False):
                    # Directory mtimes only record entry churn (for example
                    # Finder .DS_Store writes), not edits; inspect contents.
                    if path.is_mount() or os.path.lexists(path / '.git'):
                        raise ValueError('nested repository or mount')
                    stack.append(path)
                elif entry.name != '.DS_Store' and entry.stat(follow_symlinks=False).st_mtime >= cutoff:
                    raise ValueError('recent non-artefact edit')
    return candidates


def size(path):
    total = 0
    for child, entry in walk(path):
        info = entry.stat(follow_symlinks=False)
        # Refuse nested mounts/repos even for native cleaners; symlinks are
        # removed as links by trash/cargo, never traversed by this scanner.
        if stat.S_ISREG(info.st_mode):
            total += info.st_size
    return total


def guarded(wt, branch):
    return run(['bash', helper, '--check-worktree', str(wt), branch]).returncode == 0


def reclaim(wt, paths):
    # Cargo's target is explicit: never let workspace/config defaults choose a
    # shared cache outside the verified worktree. Other outputs move in a batch.
    cargo = shutil.which('cargo')
    trash = shutil.which('trash')
    gio = shutil.which('gio')
    pending = []
    for path in paths:
        if not safe_candidate(wt, path):
            raise ValueError('candidate changed; retained')
        size(path)  # Revalidate nested-repository/mount boundaries before cleaning.
        if path.name == 'target' and cargo:
            result = run([cargo, 'clean', '--manifest-path', str(path.parent / 'Cargo.toml'), '--target-dir', str(path)])
            if result.returncode == 0:
                continue
        pending.append(path)
    if pending:
        command = [trash] if trash else [gio, 'trash'] if gio else None
        if command is None:
            raise ValueError('no trash backend; retained')
        # Paths are absolute, so no option terminator is needed; macOS
        # /usr/bin/trash treats "--" as a missing file and exits non-zero.
        result = run(command + [str(path) for path in pending])
        if result.returncode:
            raise ValueError('trash failed; inspect retained paths')


totals = {'eligible': 0, 'reclaimed': 0, 'worktrees': 0}


def process_worktree(wt):
    if Path(os.fsdecode(git(wt, 'rev-parse', '--show-toplevel')).strip()).resolve() != wt:
        return
    # Linked worktrees have distinct private and common Git dirs.
    private = git(wt, 'rev-parse', '--absolute-git-dir').strip()
    common = git(wt, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()
    if private == common:
        return
    private_dir = Path(os.fsdecode(private))
    branch_result = run(['git', '-C', str(wt), 'symbolic-ref', '--quiet', '--short', 'HEAD'])
    branch = os.fsdecode(branch_result.stdout).strip()
    paths = idle_candidates(wt, private_dir)
    if not paths:
        return
    if not guarded(wt, branch):
        raise ValueError('live cwd, owner claim or active session')
    sizes = {path: size(path) for path in paths}
    for path in paths:
        print(f'[worktree-artefacts] {"eligible" if args.force else "dry-run"} path={str(path)!r} bytes={sizes[path]}', flush=True)
    if args.force:
        # Recheck age, ownership, cwd and Git exceptions immediately
        # before any cleaner, not only at discovery time.
        if idle_candidates(wt, private_dir) != paths or not guarded(wt, branch):
            raise ValueError('state changed before reclaim; retained')
        reclaim(wt, paths)
    reclaimed = sum(value for path, value in sizes.items() if not path.exists()) if args.force else 0
    totals['eligible'] += sum(sizes.values())
    totals['reclaimed'] += reclaimed
    totals['worktrees'] += 1
    print(f'[worktree-artefacts] worktree={str(wt)!r} eligible_bytes={sum(sizes.values())} reclaimed_bytes={reclaimed}', flush=True)


def main():
    if not base.is_dir() or base.is_symlink():
        print('[worktree-artefacts] no usable worktree base')
        return
    root = base.resolve()
    # Only immediate children of the configured flat worktree base qualify.
    # Visit the longest-idle roots first so a short daily budget reaches the
    # most likely candidates instead of rescanning the same directory order.
    with os.scandir(root) as entries:
        children = sorted(
            (entry for entry in entries if entry.is_dir(follow_symlinks=False)),
            key=lambda entry: entry.stat(follow_symlinks=False).st_mtime,
        )
    for entry in children:
        remaining()
        wt = Path(entry.path)
        if not (wt / '.git').is_file() or (wt / '.git').is_symlink():
            continue
        try:
            process_worktree(wt)
        except (OSError, ValueError) as error:
            print(f'[worktree-artefacts] skipped worktree={str(wt)!r} reason={str(error)!r}', flush=True)


exhausted = False
try:
    main()
except (TimeoutError, subprocess.TimeoutExpired):
    exhausted = True
    print('[worktree-artefacts] budget exhausted; remaining output retained', flush=True)
print(f'[worktree-artefacts] summary mode={"force" if args.force else "dry-run"} worktrees={totals["worktrees"]} '
      f'eligible_bytes={totals["eligible"]} reclaimed_bytes={totals["reclaimed"]} budget_exhausted={str(exhausted).lower()}', flush=True)
PY
