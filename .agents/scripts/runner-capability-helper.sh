#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Runner-local preclaim requirements; no GitHub writes or secret output.

# GH#33399: never fall back to prefetched requirements. Shared by the early
# admission gate and the final gate immediately before the persistent claim.
runner_capability_check_fresh() {
	local repo_path="$1" issue_number="$2" repo_slug="$3" logfile="$4"
	# Tool stderr may be a socket: duplicate it, never reopen /dev/stderr.
	# Function-scoped redirections restore the caller's descriptor on return.
	if [[ "$logfile" == /dev/stderr ]]; then
		_runner_capability_check_fresh_logged "$repo_path" "$issue_number" "$repo_slug" 3>&2 || return 1
	else
		_runner_capability_check_fresh_logged "$repo_path" "$issue_number" "$repo_slug" 3>>"$logfile" || return 1
	fi
	return 0
}

_runner_capability_check_fresh_logged() {
	local repo_path="$1" issue_number="$2" repo_slug="$3"
	local capability_meta_json=""
	local reason=""
	capability_meta_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '{number, state, body, labels}' 2>/dev/null) || capability_meta_json=""
	if ! printf '%s' "$capability_meta_json" | jq -e --argjson number "$issue_number" \
		'.number == $number and .state == "open" and (.body | type == "string") and (.labels | type == "array")' >/dev/null 2>&1; then
		printf '[dispatch_with_dedup] #%s deferred: runner_capability_unmet source=fresh metadata_unreadable\n' "$issue_number" >&3
		return 1
	fi
	if ! reason=$(runner_capability_check "$repo_path" "$capability_meta_json" fresh 2>&3); then
		printf '[dispatch_with_dedup] #%s deferred: %s\n' "$issue_number" "$reason" >&3
		return 1
	fi
	return 0
}

runner_capability_check() {
	local repo_path="$1"
	local issue_meta_json="$2"
	local source="${3:-}"
	local cycle="${_PULSE_CYCLE_ID:-}"
	python3 - "$repo_path" "$issue_meta_json" "$source" "$cycle" <<'PY'
import contextlib
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path

def unmet(reason=''):
    print('runner_capability_unmet' + (f' reason={reason}' if reason else ''))
    raise SystemExit(1)

def run_check(argv, target, secret=False, cwd=None):
    # Bound descendants too: a locked pinentry or probe child must not survive.
    try:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
    except OSError:
        return f'check_failed {target}' if secret else f'probe_failed {target}'
    try:
        status = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return f'check_timeout {target}'
    if not status:
        return ''
    if secret:
        if status == 3:
            return f'secret_unreadable {target} store=gopass fallback=disabled'
        return f'{"secret_missing" if status == 1 else "check_failed"} {target}'
    return f'probe_failed {target}'

@contextlib.contextmanager
def cycle_state(cycle):
    # Pulse watchdogs isolate candidates in subshells. Share metadata, not values,
    # under an exclusive lock so concurrent candidates cannot decrypt twice.
    if not cycle:
        yield None, {}
        return
    base = Path(os.environ.get('AIDEVOPS_TEMP_DIR') or
                str(Path.home() / '.aidevops/.agent-workspace/tmp'))
    directory = base / 'runner-capability'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if directory.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        unmet('cycle_state_unreadable')
    # Expired cycle files contain only names/counts; retain a day for diagnostics.
    for old in directory.glob('*.json'):
        try:
            if not old.is_symlink() and old.stat().st_mtime < time.time() - 86400:
                old.unlink()
        except FileNotFoundError:
            pass
    path = directory / (hashlib.sha256(cycle.encode()).hexdigest() + '.json')
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            unmet('cycle_state_unreadable')
        fcntl.flock(handle, fcntl.LOCK_EX)
        data = handle.read()
        state = json.loads(data) if data else {}
        yield handle, state

def unreadable(name, handle, state, cached=False):
    count = state.get('deferred', 0) + 1
    if handle is not None:
        handle.seek(0)
        json.dump({'name': name, 'deferred': count}, handle)
        handle.truncate()
        handle.flush()
    if sys.argv[3] == 'fresh' and not cached:
        print('runner_health: gpg store locked or entry unreadable; '
              'secret-gated candidates deferred>=1; gopass authoritative '
              '(no plaintext fallback); see reference/secret-handling.md', file=sys.stderr)
    if sys.argv[3] == 'fresh':
        print(f'runner_capability_health secret_gated_deferred={count}', file=sys.stderr)
    unmet(f'secret_unreadable name={name} store=gopass fallback=disabled' +
          (' source=cycle_cache' if cached else ''))

try:
    root = Path(sys.argv[1]).resolve(strict=True)
    issue = json.loads(sys.argv[2])
    config_path = root / '.aidevops.json'
    if config_path.is_symlink():
        unmet()
    config = json.loads(config_path.read_text()) if config_path.exists() else {}
    classes = config.get('dispatch_class_requirements', {})
    if not isinstance(classes, dict):
        unmet()
    requirements = []
    for label in issue.get('labels', []):
        name = label.get('name', '') if isinstance(label, dict) else label
        if name.startswith('dispatch-class:'):
            requirement = classes.get(name[len('dispatch-class:'):], {})
            if not isinstance(requirement, dict):
                unmet()
            requirements.append(requirement)
    # Issue text can name secrets, never executable commands.
    for line in issue.get('body', '').splitlines():
        if line.startswith('requires-secrets:'):
            names = re.split(r'[,\s]+', line.partition(':')[2].strip())
            if not names or not all(names):
                unmet()
            requirements.append({'secrets': names})
    secrets, probes = set(), []
    for requirement in requirements:
        names = requirement.get('secrets', [])
        if not isinstance(names, list) or len(names) > 32:
            unmet()
        for name in names:
            if not isinstance(name, str) or not re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', name):
                unmet()
            secrets.add(name)
        if 'probe' in requirement:
            probe = requirement['probe']
            # A literal executable path, not shell syntax, arguments or an URL.
            if not isinstance(probe, str) or not re.fullmatch(r'[A-Za-z0-9_./-]+', probe):
                unmet()
            path = Path(probe)
            if path.is_absolute() or '..' in path.parts:
                unmet()
            try:
                executable = (root / path).resolve(strict=True)
            except OSError:
                unmet(f'probe_failed path={probe}')
            if root not in executable.parents or not executable.is_file() or not os.access(executable, os.X_OK):
                unmet(f'probe_failed path={probe}')
            probes.append((str(executable), probe))
    if len(secrets) > 32 or len(probes) > 8:
        unmet()
    if sys.argv[3] == 'fresh':
        print(f'runner_capability_check source=fresh requirements={len(secrets) + len(probes)}',
              file=sys.stderr)
    if secrets:
        cycle = sys.argv[4] if sys.argv[3] == 'fresh' else ''
        with cycle_state(cycle) as (handle, state):
            cached_name = state.get('name', '')
            if re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', cached_name):
                unreadable(cached_name, handle, state, cached=True)
            for name in sorted(secrets):
                reason = run_check(['aidevops', 'secret', 'check', name], f'name={name}', secret=True)
                if reason.startswith('secret_unreadable '):
                    unreadable(name, handle, state)
                if reason:
                    unmet(reason)
    for executable, probe in probes:
        reason = run_check([executable], f'path={probe}', cwd=root)
        if reason:
            unmet(reason)
except (OSError, ValueError, TypeError, AttributeError, RuntimeError):
    unmet()
PY
	local rc=$?
	[[ "$rc" -eq 0 ]] || return 1
	return 0
}
