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
	capability_meta_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '{number, state, body, labels}' 2>/dev/null) || capability_meta_json=""
	if ! printf '%s' "$capability_meta_json" | jq -e --argjson number "$issue_number" \
		'.number == $number and .state == "open" and (.body | type == "string") and (.labels | type == "array")' >/dev/null 2>&1; then
		printf '[dispatch_with_dedup] #%s deferred: runner_capability_unmet source=fresh metadata_unreadable\n' "$issue_number" >&3
		return 1
	fi
	if ! runner_capability_check "$repo_path" "$capability_meta_json" fresh >/dev/null 2>&3; then
		printf '[dispatch_with_dedup] #%s deferred: runner_capability_unmet\n' "$issue_number" >&3
		return 1
	fi
	return 0
}

runner_capability_check() {
	local repo_path="$1"
	local issue_meta_json="$2"
	local source="${3:-}"
	python3 - "$repo_path" "$issue_meta_json" "$source" <<'PY'
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

def unmet():
    print('runner_capability_unmet')
    raise SystemExit(1)

def run_check(argv, cwd=None):
    # Bound descendants too: a locked pinentry or probe child must not survive.
    process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    try:
        status = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        unmet()
    if status:
        unmet()

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
            executable = (root / path).resolve(strict=True)
            if root not in executable.parents or not executable.is_file() or not os.access(executable, os.X_OK):
                unmet()
            probes.append(str(executable))
    if len(secrets) > 32 or len(probes) > 8:
        unmet()
    if sys.argv[3] == 'fresh':
        print(f'runner_capability_check source=fresh requirements={len(secrets) + len(probes)}',
              file=sys.stderr)
    for name in sorted(secrets):
        run_check(['aidevops', 'secret', 'check', name])
    for probe in probes:
        run_check([probe], cwd=root)
except (OSError, ValueError, TypeError, AttributeError, RuntimeError):
    unmet()
PY
	local rc=$?
	[[ "$rc" -eq 0 ]] || return 1
	return 0
}
