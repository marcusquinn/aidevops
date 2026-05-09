#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-current-state-helper.sh — current pulse productivity snapshot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

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
	python3 - "$log_dir" "$repo_path" "$window_s" "$as_json" "$SCRIPT_DIR" <<'PY'
import datetime
import json
import os
import subprocess
import sys
import time
from collections import Counter, defaultdict

log_dir, repo_path, window_s, as_json, script_dir = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == '1', sys.argv[5]
now = time.time()
since = now - window_s


def recent_lines(path, limit=2000):
    if not os.path.exists(path):
        return []
    with open(path, 'r', encoding='utf-8', errors='replace') as handle:
        lines = handle.readlines()[-limit:]
    return [line.rstrip('\n') for line in lines]


def parse_time(value):
    value = str(value).strip()
    if not value:
        return 0.0
    try:
        return float(value)
    except ValueError:
        pass
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return 0.0


def parse_stage(line):
    parts = line.split('\t')
    if not parts:
        return None
    ts = parse_time(parts[0])
    if ts < since:
        return None
    return {
        'ts': ts,
        'issue': parts[1] if len(parts) > 1 else '',
        'repo': parts[2] if len(parts) > 2 else '',
        'stage': parts[3] if len(parts) > 3 else 'unknown',
        'duration_ms': int(parts[4]) if len(parts) > 4 and str(parts[4]).isdigit() else 0,
    }


def classify_metric(item):
    result = str(item.get('result') or 'unknown')
    failure_reason = str(item.get('failure_reason') or '')
    exit_code = item.get('exit_code')
    if result == 'success' and exit_code == 0:
        return 'success'
    if result in {'watchdog_stall_killed', 'watchdog_stall_continue'}:
        return result
    if result in {'rate_limit', 'rate_limit_fast'} or 'rate_limit' in failure_reason:
        return 'rate_limit'
    if result in {'worker_noop', 'no_work', 'noop'}:
        return 'worker_noop'
    return result


def line_count(patterns, lines):
    count = 0
    examples = []
    for line in lines:
        lower = line.lower()
        if any(pattern in lower for pattern in patterns):
            count += 1
            if len(examples) < 3:
                examples.append(line[-180:])
    return count, examples


stage_records = []
for line in recent_lines(os.path.join(log_dir, 'dispatch-stages.tsv')):
    record = parse_stage(line)
    if record:
        stage_records.append(record)
metrics = []
for line in recent_lines(os.path.join(log_dir, 'headless-runtime-metrics.jsonl')):
    try:
        item = json.loads(line)
    except json.JSONDecodeError:
        continue
    if float(item.get('ts', 0)) >= since:
        metrics.append(item)

counter_hits = {}
gauge_values = {}
stats_path = os.path.join(log_dir, 'pulse-stats.json')
if os.path.exists(stats_path):
    try:
        stats = json.load(open(stats_path, encoding='utf-8'))
        for key, values in (stats.get('counters') or {}).items():
            if isinstance(values, list):
                hits = [v for v in values if isinstance(v, (int, float)) and v >= since]
                if hits:
                    counter_hits[key] = len(hits)
        for key, item in (stats.get('gauges') or {}).items():
            if isinstance(item, dict) and float(item.get('ts', 0)) >= since:
                gauge_values[key] = item.get('value')
    except (OSError, json.JSONDecodeError):
        counter_hits = {}
        gauge_values = {}

wrapper_activity = []
for line in recent_lines(os.path.join(log_dir, 'pulse-wrapper.log'), 400):
    if 'Instance lock acquired' in line or 'detector-loop' in line:
        continue
    if line.strip():
        wrapper_activity.append(line)
wrapper_activity = wrapper_activity[-10:]

metric_class_counts = Counter(classify_metric(item) for item in metrics)
stage_counts = Counter(record['stage'] for record in stage_records)
stage_timing = defaultdict(lambda: {'count': 0, 'sum_ms': 0, 'max_ms': 0})
for record in stage_records:
    item = stage_timing[record['stage']]
    item['count'] += 1
    item['sum_ms'] += record['duration_ms']
    item['max_ms'] = max(item['max_ms'], record['duration_ms'])
stage_timing_summary = {
    key: {
        'count': value['count'],
        'avg_ms': int(value['sum_ms'] / value['count']) if value['count'] else 0,
        'max_ms': value['max_ms'],
    }
    for key, value in stage_timing.items()
}

worker_spawn_count = stage_counts.get('worker_launch_total', 0) + sum(
    1 for line in wrapper_activity if 'worker_start' in line or 'worker_started' in line
)
canary_fail_count = counter_hits.get('worker_canary_preflight_failed_count', 0) + sum(
    1 for line in wrapper_activity if 'canary failed' in line.lower()
)
load_blocked_count = counter_hits.get('dispatch_load_blocked', 0) + sum(
    1 for line in wrapper_activity if 'system overloaded' in line.lower() or 'load-blocked' in line.lower()
)
rate_limit_count = metric_class_counts.get('rate_limit', 0)
watchdog_kill_count = metric_class_counts.get('watchdog_stall_killed', 0)
noop_count = metric_class_counts.get('worker_noop', 0)
pr_opened_count, pr_opened_examples = line_count(['pr opened', 'opened pr', 'pull request'], wrapper_activity)
pr_merged_count, pr_merged_examples = line_count(['pr merged', 'merged pr', 'squash merged'], wrapper_activity)
issue_closed_count, issue_closed_examples = line_count(['issue closed', 'closed issue', 'status:done'], wrapper_activity)
graphql_budget = {
    'skipped_low_count': counter_hits.get('pulse_cycle_skipped_graphql_low', 0),
    'circuit_broken_count': counter_hits.get('pulse_dispatch_circuit_broken', 0),
    'prefetch_throttled_count': counter_hits.get('pulse_prefetch_budget_throttled', 0),
    'force_rest_reads_count': counter_hits.get('pulse_graphql_low_force_rest_reads', 0),
    'reserve_mode_count': counter_hits.get('pulse_graphql_budget_reserve_mode', 0),
    'deferred_stage_count': counter_hits.get('pulse_graphql_budget_stage_deferred', 0),
    'deferred_stages': {
        key[len('pulse_graphql_budget_stage_deferred_'):]: count
        for key, count in sorted(counter_hits.items())
        if key.startswith('pulse_graphql_budget_stage_deferred_')
    },
    'gauges': {k: v for k, v in gauge_values.items() if 'graphql' in k.lower() or 'budget' in k.lower() or 'rate' in k.lower()},
}
dispatch_pacing = {
    'inter_launch_staggered_count': counter_hits.get('dispatch_inter_launch_staggered', 0),
    'last_inter_launch_delay_seconds': gauge_values.get('dispatch_inter_launch_delay_seconds'),
}
pre_launch_blockers = {}
for key, count in counter_hits.items():
    prefix = 'dispatch_candidate_failed_reason_'
    if key.startswith(prefix):
        pre_launch_blockers[key[len(prefix):]] = pre_launch_blockers.get(key[len(prefix):], 0) + count
if counter_hits.get('dispatch_graphql_circuit_blocked', 0):
    pre_launch_blockers['graphql_circuit_breaker'] = max(
        pre_launch_blockers.get('graphql_circuit_breaker', 0),
        counter_hits.get('dispatch_graphql_circuit_blocked', 0),
    )
if counter_hits.get('pulse_dispatch_runner_health_breaker_tripped', 0):
    pre_launch_blockers['runner_health_circuit_breaker'] = max(
        pre_launch_blockers.get('runner_health_circuit_breaker', 0),
        counter_hits.get('pulse_dispatch_runner_health_breaker_tripped', 0),
    )
for guardrail_reason in ('provider_rate_limit_pressure', 'repeated_failure_pressure', 'healthy_pr_backlog', 'no_dispatchable_evidence'):
    counter_name = f'dispatch_candidate_failed_reason_{guardrail_reason}'
    if counter_hits.get(counter_name, 0):
        pre_launch_blockers[guardrail_reason] = max(
            pre_launch_blockers.get(guardrail_reason, 0),
            counter_hits.get(counter_name, 0),
        )
top_pre_launch_blockers = [
    {'reason': reason, 'count': count}
    for reason, count in sorted(pre_launch_blockers.items(), key=lambda item: (-item[1], item[0]))
]

worktrees = []
try:
    out = subprocess.check_output(['git', '-C', repo_path, 'worktree', 'list'], text=True, stderr=subprocess.DEVNULL)
    worktrees = [line for line in out.splitlines() if 'feature/auto-' in line or 'feature/gh-' in line]
except (OSError, subprocess.CalledProcessError):
    worktrees = []

graphql_budget_status = 'UNKNOWN: no cached status'
breaker = os.path.join(script_dir, 'pulse-rate-limit-circuit-breaker.sh')
try:
    graphql_budget_status = subprocess.check_output(
        [breaker, 'status', '--cached'], text=True, stderr=subprocess.DEVNULL, timeout=5
    ).strip() or graphql_budget_status
except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
    pass
dispatch_api_blocked = (
    graphql_budget_status.startswith('TRIPPED:')
    or (
        not graphql_budget_status.startswith('OK:')
        and (
            graphql_budget['skipped_low_count'] > 0
            or graphql_budget['circuit_broken_count'] > 0
            or pre_launch_blockers.get('graphql_circuit_breaker', 0) > 0
        )
    )
)
current_state_guardrails = {
    'applied_count': counter_hits.get('pulse_dispatch_current_state_guardrail_applied', 0),
    'available_slots_last': gauge_values.get('pulse_dispatch_guardrail_available_slots'),
    'reasons': {
        reason: pre_launch_blockers.get(reason, 0)
        for reason in ('provider_rate_limit_pressure', 'repeated_failure_pressure', 'healthy_pr_backlog', 'no_dispatchable_evidence')
        if pre_launch_blockers.get(reason, 0)
    },
}

api_consumers = []
api_pressure = {
    'graphql_read_calls': 0,
    'rest_read_calls': 0,
    'graphql_search_calls': 0,
    'rest_search_calls': 0,
    'graphql_other_calls': 0,
    'read_rest_ratio': None,
    'top_read_graphql_callers': [],
    'shadow_mode': 'gh shim records operation-specific read/list callers; REST rows are before/after counter for fallback routing',
}
api_report = os.path.join(log_dir, 'gh-api-calls-by-stage.json')
if os.path.exists(api_report):
    try:
        report = json.load(open(api_report, encoding='utf-8'))
        read_graphql_callers = []
        read_caller_names = {'gh_issue_list', 'gh_pr_list', 'gh_issue_view', 'gh_pr_view'}
        rest_read_caller_names = {'_rest_issue_list', '_rest_pr_list', '_rest_issue_view', '_rest_pr_view'}
        for caller, data in (report.get('by_caller') or {}).items():
            if isinstance(data, dict):
                gql = int(data.get('graphql_calls') or 0) + int(data.get('search_graphql_calls') or 0)
                if gql > 0:
                    api_consumers.append({'caller': caller, 'graphql_calls': gql})
                graphql_calls = int(data.get('graphql_calls') or 0)
                rest_calls = int(data.get('rest_calls') or 0)
                search_graphql_calls = int(data.get('search_graphql_calls') or 0)
                search_rest_calls = int(data.get('search_rest_calls') or 0)
                if caller in read_caller_names:
                    api_pressure['graphql_read_calls'] += graphql_calls
                    api_pressure['rest_read_calls'] += rest_calls
                    if graphql_calls > 0:
                        read_graphql_callers.append({'caller': caller, 'graphql_calls': graphql_calls})
                elif caller in rest_read_caller_names:
                    api_pressure['rest_read_calls'] += rest_calls
                else:
                    api_pressure['graphql_other_calls'] += graphql_calls
                api_pressure['graphql_search_calls'] += search_graphql_calls
                api_pressure['rest_search_calls'] += search_rest_calls
        api_consumers = sorted(api_consumers, key=lambda item: item['graphql_calls'], reverse=True)[:5]
        read_total = api_pressure['graphql_read_calls'] + api_pressure['rest_read_calls']
        if read_total > 0:
            api_pressure['read_rest_ratio'] = round(api_pressure['rest_read_calls'] / read_total, 4)
        api_pressure['top_read_graphql_callers'] = sorted(
            read_graphql_callers, key=lambda item: item['graphql_calls'], reverse=True
        )[:5]
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        api_consumers = []
        api_pressure = {
            'graphql_read_calls': 0,
            'rest_read_calls': 0,
            'graphql_search_calls': 0,
            'rest_search_calls': 0,
            'graphql_other_calls': 0,
            'read_rest_ratio': None,
            'top_read_graphql_callers': [],
            'shadow_mode': 'unavailable: failed to parse gh-api report',
        }

prefetch_cache = {
    'batch_cache_hits': 0,
    'conditional_304': 0,
    'conditional_refreshes': 0,
    'conditional_misses': 0,
}
health_path = os.path.join(log_dir, 'pulse-health.json')
if os.path.exists(health_path):
    try:
        health = json.load(open(health_path, encoding='utf-8'))
        prefetch_cache = {
            'batch_cache_hits': int(health.get('batch_cache_hits') or 0),
            'conditional_304': int(health.get('prefetch_conditional_304') or 0),
            'conditional_refreshes': int(health.get('prefetch_conditional_refreshes') or 0),
            'conditional_misses': int(health.get('prefetch_conditional_misses') or 0),
        }
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        pass

result = {
    'window_seconds': window_s,
    'dispatch_stage_events': len(stage_records),
    'dispatch_stage_counts': dict(stage_counts),
    'dispatch_stage_timing_ms': stage_timing_summary,
    'worker_terminal_events': len(metrics),
    'worker_result_counts': dict(metric_class_counts),
    'worker_successes': metric_class_counts.get('success', 0),
    'worker_failures_or_stalls': sum(count for key, count in metric_class_counts.items() if key != 'success'),
    'worker_outcomes': {
        'spawned': worker_spawn_count,
        'canary_failed': canary_fail_count,
        'watchdog_killed': watchdog_kill_count,
        'rate_limited': rate_limit_count,
        'no_op': noop_count,
        'pr_opened': pr_opened_count,
        'pr_merged': pr_merged_count,
        'issue_closed': issue_closed_count,
    },
    'worker_outcome_examples': {
        'pr_opened': pr_opened_examples,
        'pr_merged': pr_merged_examples,
        'issue_closed': issue_closed_examples,
    },
    'resource_context': {
        'load_1min_last': next((item.get('load_1min') for item in reversed(metrics) if item.get('load_1min') is not None), None),
        'load_per_cpu_last': next((item.get('load_per_cpu') for item in reversed(metrics) if item.get('load_per_cpu') is not None), None),
        'load_blocked_count': load_blocked_count,
    },
    'graphql_budget': graphql_budget,
    'dispatch_pacing': dispatch_pacing,
    'current_state_guardrails': current_state_guardrails,
    'pre_launch_blockers': pre_launch_blockers,
    'top_pre_launch_blockers': top_pre_launch_blockers[:5],
    'pulse_counter_hits': counter_hits,
    'pulse_gauges': gauge_values,
    'wrapper_activity_lines': len(wrapper_activity),
    'worker_worktrees': len(worktrees),
    'dispatch_alive': bool(stage_records or metrics or counter_hits or worktrees),
    'graphql_budget_status': graphql_budget_status,
    'dispatch_api_blocked': dispatch_api_blocked,
    'top_graphql_consumers': api_consumers,
    'api_call_pressure': api_pressure,
    'prefetch_cache': prefetch_cache,
}

if as_json:
    print(json.dumps(result, indent=2, sort_keys=True))
else:
    print('Pulse current-state snapshot')
    print(f'- Window: {window_s}s')
    print(f'- Dispatch alive: {str(result["dispatch_alive"]).lower()}')
    print(f'- Dispatch stage events: {result["dispatch_stage_events"]}')
    print(f'- Dispatch stage counts: {json.dumps(result["dispatch_stage_counts"], sort_keys=True)}')
    print(f'- Worker terminal events: {result["worker_terminal_events"]} ({result["worker_successes"]} success, {result["worker_failures_or_stalls"]} non-success)')
    print(f'- Worker outcomes: {json.dumps(result["worker_outcomes"], sort_keys=True)}')
    print(f'- Resource context: {json.dumps(result["resource_context"], sort_keys=True)}')
    print(f'- GraphQL budget: {json.dumps(result["graphql_budget"], sort_keys=True)}')
    print(f'- Dispatch pacing: {json.dumps(result["dispatch_pacing"], sort_keys=True)}')
    print(f'- Current-state guardrails: {json.dumps(result["current_state_guardrails"], sort_keys=True)}')
    print(f'- Top pre-launch blockers: {json.dumps(result["top_pre_launch_blockers"], sort_keys=True)}')
    print(f'- Pulse counter hits: {json.dumps(counter_hits, sort_keys=True)}')
    print(f'- GraphQL budget: {graphql_budget_status}')
    print(f'- Prefetch cache: {json.dumps(prefetch_cache, sort_keys=True)}')
    print(f'- Dispatch API blocked by GraphQL: {str(dispatch_api_blocked).lower()}')
    if api_consumers:
        print(f'- Top GraphQL consumers: {json.dumps(api_consumers)}')
    print(f'- API call pressure: {json.dumps(api_pressure, sort_keys=True)}')
    print(f'- Worker worktrees: {result["worker_worktrees"]}')
    if wrapper_activity:
        print('- Recent wrapper activity:')
        for line in wrapper_activity[-3:]:
            print(f'  - {line[-180:]}')
PY
	return 0
}

main "$@"
