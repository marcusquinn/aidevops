#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../pulse-current-state-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$TMP_DIR" <<'PY'
import json, os, sys, time
root = sys.argv[1]
now = time.time()
iso = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))
open(os.path.join(root, 'dispatch-stages.tsv'), 'w').write(
    f'{iso}\t#1\tmarcusquinn/aidevops\tworker_launch_total\t123\n'
    f'{iso}\t#1\tmarcusquinn/aidevops\tceremony_total\t456\n'
)
open(os.path.join(root, 'headless-runtime-metrics.jsonl'), 'w').write(
    json.dumps({'ts': now, 'result': 'success', 'exit_code': 0, 'duration_ms': 1000, 'load_1min': 1.5, 'load_per_cpu': 0.2}) + '\n' +
    json.dumps({'ts': now, 'result': 'watchdog_stall_killed', 'exit_code': 79, 'duration_ms': 2000}) + '\n' +
    json.dumps({'ts': now, 'result': 'rate_limit_fast', 'exit_code': 80, 'failure_reason': 'rate_limit_fast'}) + '\n' +
    json.dumps({'ts': now, 'result': 'worker_noop', 'exit_code': 2}) + '\n'
)
json.dump({
    'counters': {
        'dispatch_backoff_skipped': [now],
        'worker_canary_preflight_failed_count': [now],
        'pulse_cycle_skipped_graphql_low': [now],
        'dispatch_load_blocked': [now],
        'dispatch_candidate_failed': [now, now, now, now],
        'dispatch_candidate_failed_reason_cost_budget_exceeded': [now, now],
        'dispatch_candidate_failed_reason_dedup_active_claim': [now],
        'dispatch_candidate_failed_reason_graphql_circuit_breaker': [now],
    },
    'gauges': {'graphql_remaining': {'value': 1234, 'ts': now}},
}, open(os.path.join(root, 'pulse-stats.json'), 'w'))
json.dump({
    '_meta': {'total_calls': 42},
    'by_caller': {
        'gh_issue_list': {'graphql_calls': 7, 'rest_calls': 3, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 10},
        'gh_pr_view': {'graphql_calls': 2, 'rest_calls': 0, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 2},
        '_rest_pr_list': {'graphql_calls': 0, 'rest_calls': 5, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 5},
        'pulse-batch-prefetch-helper.sh': {'graphql_calls': 0, 'rest_calls': 0, 'search_graphql_calls': 11, 'search_rest_calls': 4, 'other_calls': 0, 'total': 15},
        'gh_api_graphql': {'graphql_calls': 10, 'rest_calls': 0, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 10},
    }
}, open(os.path.join(root, 'gh-api-calls-by-stage.json'), 'w'))
open(os.path.join(root, 'pulse-wrapper.log'), 'w').write('[pulse] useful activity\nPR opened #2\nPR merged #2\nissue closed #1\nInstance lock acquired\n')
PY

output="$TMP_DIR/out.txt"
"$HELPER" --log-dir "$TMP_DIR" --repo-path "$PWD" --window 15m >"$output"

grep -q 'Dispatch alive: true' "$output"
grep -q 'Worker terminal events: 4' "$output"
grep -q 'dispatch_backoff_skipped' "$output"
grep -q 'GraphQL budget:' "$output"
grep -q 'Top pre-launch blockers:' "$output"
grep -q 'API call pressure:' "$output"
grep -q 'worker_launch_total' "$output"
grep -q 'watchdog_killed' "$output"
grep -q 'rate_limited' "$output"
grep -q 'canary_failed' "$output"

json_output="$TMP_DIR/out.json"
"$HELPER" --log-dir "$TMP_DIR" --repo-path "$PWD" --window 15m --json >"$json_output"
jq -e '.worker_outcomes.spawned == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.watchdog_killed == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.rate_limited == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.no_op == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.canary_failed == 1' "$json_output" >/dev/null
jq -e '.graphql_budget.skipped_low_count == 1' "$json_output" >/dev/null
jq -e '.pre_launch_blockers.cost_budget_exceeded == 2' "$json_output" >/dev/null
jq -e '.pre_launch_blockers.dedup_active_claim == 1' "$json_output" >/dev/null
jq -e '.top_pre_launch_blockers[0].reason == "cost_budget_exceeded"' "$json_output" >/dev/null
jq -e '.dispatch_stage_timing_ms.worker_launch_total.avg_ms == 123' "$json_output" >/dev/null
jq -e '.api_call_pressure.graphql_read_calls == 9' "$json_output" >/dev/null
jq -e '.api_call_pressure.rest_read_calls == 8' "$json_output" >/dev/null
jq -e '.api_call_pressure.graphql_search_calls == 11' "$json_output" >/dev/null
jq -e '.api_call_pressure.rest_search_calls == 4' "$json_output" >/dev/null
jq -e '.api_call_pressure.graphql_other_calls == 10' "$json_output" >/dev/null
jq -e '.api_call_pressure.read_rest_ratio == 0.4706' "$json_output" >/dev/null

printf 'PASS pulse-current-state-helper\n'
