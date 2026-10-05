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
	# Sourcing this helper at both gates must not reset cycle-local health state.
	local cycle="${_PULSE_CYCLE_ID:-}" cached_name="" reason=""
	if [[ "${_RUNNER_CAPABILITY_CYCLE:-}" != "$cycle" ]]; then
		_RUNNER_CAPABILITY_CYCLE="$cycle"
		_RUNNER_CAPABILITY_LOCKED_NAME=""
		_RUNNER_CAPABILITY_DEFERRED=0
	fi
	[[ -z "$cycle" ]] || cached_name="${_RUNNER_CAPABILITY_LOCKED_NAME:-}"
	capability_meta_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '{number, state, body, labels}' 2>/dev/null) || capability_meta_json=""
	if ! printf '%s' "$capability_meta_json" | jq -e --argjson number "$issue_number" \
		'.number == $number and .state == "open" and (.body | type == "string") and (.labels | type == "array")' >/dev/null 2>&1; then
		printf '[dispatch_with_dedup] #%s deferred: runner_capability_unmet source=fresh metadata_unreadable\n' "$issue_number" >&3
		return 1
	fi
	if ! reason=$(runner_capability_check "$repo_path" "$capability_meta_json" fresh "$cached_name" 2>&3); then
		printf '[dispatch_with_dedup] #%s deferred: %s\n' "$issue_number" "$reason" >&3
		if [[ "$reason" == 'runner_capability_unmet reason=secret_unreadable name='* ]]; then
			_RUNNER_CAPABILITY_DEFERRED=$((${_RUNNER_CAPABILITY_DEFERRED:-0} + 1))
			if [[ -z "$cached_name" ]]; then
				_RUNNER_CAPABILITY_LOCKED_NAME="${reason#* name=}"
				_RUNNER_CAPABILITY_LOCKED_NAME="${_RUNNER_CAPABILITY_LOCKED_NAME%% *}"
				printf 'runner_health: gpg store locked or entry unreadable; secret-gated candidates deferred>=1; gopass authoritative (no plaintext fallback); see reference/secret-handling.md\n' >&3
			fi
			printf 'runner_capability_health secret_gated_deferred=%s cycle=%s\n' "$_RUNNER_CAPABILITY_DEFERRED" "$cycle" >&3
		fi
		return 1
	fi
	return 0
}

runner_capability_check() {
	local repo_path="$1"
	local issue_meta_json="$2"
	local source="${3:-}"
	local cached_name="${4:-}"
	python3 - "$repo_path" "$issue_meta_json" "$source" "$cached_name" <<'PY'
import json
import os
import re
import signal
import subprocess
import sys
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
    if secrets and re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', sys.argv[4]):
        unmet(f'secret_unreadable name={sys.argv[4]} store=gopass fallback=disabled source=cycle_cache')
    for name in sorted(secrets):
        reason = run_check(['aidevops', 'secret', 'check', name], f'name={name}', secret=True)
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
