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
		_runner_capability_log_deferral "$issue_number" "$repo_slug" \
			'runner_capability_unmet source=fresh metadata_unreadable' metadata_unreadable
		return 1
	fi
	if ! reason=$(runner_capability_check "$repo_path" "$capability_meta_json" fresh 2>&3); then
		_runner_capability_log_deferral "$issue_number" "$repo_slug" "$reason" ""
		return 1
	fi
	return 0
}

# GH#33743: keep the operator-facing "deferred:" text, and append a structured
# reason with the repo slug so candidate-scoped log matching classifies it as
# runner_capability_unmet instead of no_recent_log_evidence. cooldown=eligible
# marks deterministic runner-local gaps (missing secret, failing probe, invalid
# requirement map); transient store/API/timeout signals are always re-checked.
_runner_capability_log_deferral() {
	local issue_number="$1" repo_slug="$2" reason="$3" signal="$4"
	local cooldown="none"
	reason="${reason//$'\n'/ }"
	if [[ -z "$reason" ]]; then
		# No checker verdict (interpreter failure): never cool down on it.
		reason="runner_capability_unmet"
		[[ -n "$signal" ]] || signal="check_error"
	fi
	if [[ -z "$signal" ]]; then
		if [[ "$reason" =~ reason=([a-z_]+) ]]; then
			signal="${BASH_REMATCH[1]}"
		elif [[ "$reason" == runner_capability_unmet ]]; then
			signal="invalid_requirements"
		else
			signal="check_error"
		fi
	fi
	case "$signal" in
	secret_missing | probe_failed | invalid_requirements) cooldown="eligible" ;;
	esac
	printf '[dispatch_with_dedup] #%s deferred: %s — DISPATCH_BLOCK_REASON reason=runner_capability_unmet signal=%s cooldown=%s issue=#%s repo=%s\n' \
		"$issue_number" "$reason" "$signal" "$cooldown" "$issue_number" "$repo_slug" >&3
	return 0
}

runner_capability_check() {
	local repo_path="$1"
	local issue_meta_json="$2"
	local source="${3:-}"
	local cycle="${_PULSE_CYCLE_ID:-}"
	# Assemble only trusted literal code; issue metadata stays in argv as data.
	python3 - "$repo_path" "$issue_meta_json" "$source" "$cycle" "${BASH_SOURCE[0]%/*}/network-tier-helper.sh" < <(
		_runner_capability_python_runtime
		_runner_capability_python_cycle
		_runner_capability_python_classes
		_runner_capability_python_requirements
	)
	local rc=$?
	[[ "$rc" -eq 0 ]] || return 1
	return 0
}

_runner_capability_python_runtime() {
	cat <<'PY'
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

def run_check(argv, target, secret=False, cwd=None, timeout=5):
    # Bound descendants too: a locked pinentry or probe child must not survive.
    try:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
    except OSError:
        return f'check_failed {target}' if secret else f'probe_failed {target}'
    try:
        status = process.wait(timeout=timeout)
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

PY
	return 0
}

_runner_capability_python_cycle() {
	cat <<'PY'
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

PY
	return 0
}

_runner_capability_python_classes() {
	cat <<'PY'
def class_requirements(root, issue):
    class_names = []
    for label in issue.get('labels', []):
        name = label.get('name', '') if isinstance(label, dict) else label
        if name.startswith('dispatch-class:'):
            class_names.append(name[len('dispatch-class:'):])
    classes = {}
    # Repo config only contributes class requirements; ungated issues ignore it.
    if class_names:
        config_path = root / '.aidevops.json'
        if config_path.is_symlink():
            unmet()
        try:
            config = json.loads(config_path.read_text()) if config_path.exists() else {}
        except (ValueError, OSError):
            unmet('config_unreadable path=.aidevops.json')
        classes = config.get('dispatch_class_requirements', {})
        if not isinstance(classes, dict):
            unmet()
    requirements = []
    for name in class_names:
        requirement = classes.get(name, {})
        if not isinstance(requirement, dict):
            unmet()
        requirements.append(requirement)
    return requirements

PY
	return 0
}

_runner_capability_python_requirements() {
	cat <<'PY'
try:
    root = Path(sys.argv[1]).resolve(strict=True)
    issue = json.loads(sys.argv[2])
    requirements = class_requirements(root, issue)
    # Issue text can name secrets, never executable commands.
    for line in issue.get('body', '').splitlines():
        if line.startswith('requires-secrets:'):
            names = re.split(r'[,\s]+', line.partition(':')[2].strip())
            if not names or not all(names):
                unmet()
            requirements.append({'secrets': names})
        elif line.startswith('requires-ssh:'):
            requirements.append({'ssh_commands': [json.loads(line.partition(':')[2])]})
    secrets, probes, ssh_commands = set(), [], []
    for requirement in requirements:
        commands = requirement.get('ssh_commands', [])
        if not isinstance(commands, list) or len(commands) > 8:
            unmet('invalid_requirements')
        for command in commands:
            if (not isinstance(command, list) or not command or len(command) > 128
                    or not all(isinstance(arg, str) and len(arg) <= 4096 for arg in command)
                    or command[0] not in ('ssh', '/usr/bin/ssh')):
                unmet('invalid_requirements')
            ssh_commands.append(command)
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
    if len(secrets) > 32 or len(probes) > 8 or len(ssh_commands) > 8:
        unmet()
    # Only analyze exact argv; never execute SSH or issue-provided shell text.
    # The same tier gate used inside the worker is authoritative before claim.
    network_timeout = int(os.environ.get('AIDEVOPS_NETWORK_POLICY_TIMEOUT_SECONDS', '30'))
    if ssh_commands and network_timeout <= 0:
        unmet('invalid_requirements')
    for command in ssh_commands:
        reason = run_check(['bash', str(Path(sys.argv[5]).resolve()), 'check-argv',
                            json.dumps(command), '--cwd', str(root)],
                           'ssh', cwd=root, timeout=network_timeout)
        if reason:
            unmet('ssh_network_requirement_unmet recovery=reference/ssh-bindings.md')
    if sys.argv[3] == 'fresh':
        print(f'runner_capability_check source=fresh requirements={len(secrets) + len(probes) + len(ssh_commands)}',
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
	return 0
}
