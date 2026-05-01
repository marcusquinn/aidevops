#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-current-state-helper.sh — current pulse productivity snapshot.

set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: pulse-current-state-helper.sh [--window 15m] [--repo-path PATH] [--log-dir DIR] [--json]

Summarizes current-state pulse evidence from recent dispatch stages, worker
metrics, pulse counters, pulse wrapper log activity, and worker worktrees.
EOF
	return 0
}

_seconds() {
	local value="$1"
	case "$value" in
		*m) printf '%s\n' "$((${value%m} * 60))" ;;
		*h) printf '%s\n' "$((${value%h} * 3600))" ;;
		*) printf '%s\n' "$value" ;;
	esac
	return 0
}

main() {
	local window="15m"
	local repo_path="${AIDEVOPS_REPO_PATH:-$HOME/Git/aidevops}"
	local log_dir="${AIDEVOPS_LOG_DIR:-$HOME/.aidevops/logs}"
	local as_json=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--window) [[ $# -gt 0 ]] || { printf 'ERROR: --window requires a value\n' >&2; return 2; }; local value="$1"; window="$value"; shift ;;
			--repo-path) [[ $# -gt 0 ]] || { printf 'ERROR: --repo-path requires a value\n' >&2; return 2; }; local value="$1"; repo_path="$value"; shift ;;
			--log-dir) [[ $# -gt 0 ]] || { printf 'ERROR: --log-dir requires a value\n' >&2; return 2; }; local value="$1"; log_dir="$value"; shift ;;
			--json) as_json=1 ;;
			--help|-h) _usage; return 0 ;;
			*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	local window_s
	window_s="$(_seconds "$window")"
	python3 - "$log_dir" "$repo_path" "$window_s" "$as_json" <<'PY'
import json
import os
import subprocess
import sys
import time

log_dir, repo_path, window_s, as_json = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == '1'
now = time.time()
since = now - window_s


def recent_lines(path, limit=2000):
    if not os.path.exists(path):
        return []
    with open(path, 'r', encoding='utf-8', errors='replace') as handle:
        lines = handle.readlines()[-limit:]
    return [line.rstrip('\n') for line in lines]


def parse_stage(line):
    parts = line.split('\t')
    for part in parts:
        try:
            value = float(part)
        except ValueError:
            continue
        if value > since:
            return True
    return False


stage_lines = [line for line in recent_lines(os.path.join(log_dir, 'dispatch-stages.tsv')) if parse_stage(line)]
metrics = []
for line in recent_lines(os.path.join(log_dir, 'headless-runtime-metrics.jsonl')):
    try:
        item = json.loads(line)
    except json.JSONDecodeError:
        continue
    if float(item.get('ts', 0)) >= since:
        metrics.append(item)

counter_hits = {}
stats_path = os.path.join(log_dir, 'pulse-stats.json')
if os.path.exists(stats_path):
    try:
        stats = json.load(open(stats_path, encoding='utf-8'))
        for key, values in (stats.get('counters') or {}).items():
            if isinstance(values, list):
                hits = [v for v in values if isinstance(v, (int, float)) and v >= since]
                if hits:
                    counter_hits[key] = len(hits)
    except (OSError, json.JSONDecodeError):
        counter_hits = {}

wrapper_activity = []
for line in recent_lines(os.path.join(log_dir, 'pulse-wrapper.log'), 400):
    if 'Instance lock acquired' in line or 'detector-loop' in line:
        continue
    if line.strip():
        wrapper_activity.append(line)
wrapper_activity = wrapper_activity[-10:]

worktrees = []
try:
    out = subprocess.check_output(['git', '-C', repo_path, 'worktree', 'list'], text=True, stderr=subprocess.DEVNULL)
    worktrees = [line for line in out.splitlines() if 'feature/auto-' in line or 'feature/gh-' in line]
except (OSError, subprocess.CalledProcessError):
    worktrees = []

result = {
    'window_seconds': window_s,
    'dispatch_stage_events': len(stage_lines),
    'worker_terminal_events': len(metrics),
    'worker_successes': sum(1 for item in metrics if item.get('result') == 'success'),
    'worker_failures_or_stalls': sum(1 for item in metrics if item.get('result') and item.get('result') != 'success'),
    'pulse_counter_hits': counter_hits,
    'wrapper_activity_lines': len(wrapper_activity),
    'worker_worktrees': len(worktrees),
    'dispatch_alive': bool(stage_lines or metrics or counter_hits or worktrees),
}

if as_json:
    print(json.dumps(result, indent=2, sort_keys=True))
else:
    print('Pulse current-state snapshot')
    print(f'- Window: {window_s}s')
    print(f'- Dispatch alive: {str(result["dispatch_alive"]).lower()}')
    print(f'- Dispatch stage events: {result["dispatch_stage_events"]}')
    print(f'- Worker terminal events: {result["worker_terminal_events"]} ({result["worker_successes"]} success, {result["worker_failures_or_stalls"]} non-success)')
    print(f'- Pulse counter hits: {json.dumps(counter_hits, sort_keys=True)}')
    print(f'- Worker worktrees: {result["worker_worktrees"]}')
    if wrapper_activity:
        print('- Recent wrapper activity:')
        for line in wrapper_activity[-3:]:
            print(f'  - {line[-180:]}')
PY
	return 0
}

main "$@"
