#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Runner-local preclaim requirements; no GitHub writes or secret output.

runner_capability_check() {
	local repo_path="$1"
	local issue_meta_json="$2"
	python3 - "$repo_path" "$issue_meta_json" <<'PY'
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
