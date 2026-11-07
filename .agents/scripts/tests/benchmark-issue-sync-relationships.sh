#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
BENCHMARK_DIR=$(mktemp -d "${TEMP_PARENT}/relationship-benchmark.XXXXXX")

# shellcheck source=../issue-sync-helper.sh
source "${TEST_DIR}/../issue-sync-helper.sh"

cleanup() {
	rm -rf "$BENCHMARK_DIR"
	return 0
}
trap cleanup EXIT

stdout_file="${BENCHMARK_DIR}/stdout.log"
resource_file="${BENCHMARK_DIR}/resources.log"
started_at=$(date +%s)
benchmark_rc=0
platform=$(uname -s)

if [[ "$platform" == "Darwin" ]]; then
	AIDEVOPS_BENCHMARK_OUTPUT=1 /usr/bin/time -l \
		bash "${TEST_DIR}/test-issue-sync-relationship-resume.sh" \
		>"$stdout_file" 2>"$resource_file" || benchmark_rc=$?
	peak_rss=$(awk '/maximum resident set size/ { print int($1 / 1024); exit }' "$resource_file")
else
	AIDEVOPS_BENCHMARK_OUTPUT=1 /usr/bin/time -v \
		bash "${TEST_DIR}/test-issue-sync-relationship-resume.sh" \
		>"$stdout_file" 2>"$resource_file" || benchmark_rc=$?
	peak_rss=$(awk -F: '/Maximum resident set size/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$resource_file")
fi

[[ "$benchmark_rc" -eq 0 ]] || {
	printf 'FAIL: relationship benchmark fixture exited %d\n' "$benchmark_rc" >&2
	return "$benchmark_rc" 2>/dev/null || exit "$benchmark_rc"
}
[[ "$peak_rss" =~ ^[0-9]+$ ]] || {
	printf 'FAIL: relationship benchmark did not capture peak RSS\n' >&2
	exit 1
}

finished_at=$(date +%s)
printf 'Benchmark: candidates=800 wall_seconds=%d peak_rss_kb=%d\n' \
	"$((finished_at - started_at))" "$peak_rss"
grep -m1 '^Edges:' "$stdout_file"
grep -m1 '^Tasks:' "$stdout_file"
grep -m1 '^Workset:' "$stdout_file"
grep -m1 '^Timing:' "$stdout_file"

graph_edges=""
for ((node = 1; node <= 18; node++)); do
	graph_edges="${graph_edges}t${node}|t$((node + 1))"$'\n'
	graph_edges="${graph_edges}t${node}|t$((node + 1))"$'\n'
done
for ((node = 1; node <= 9; node++)); do
	graph_edges="${graph_edges}t${node}|t$((node + 10))"$'\n'
done
metrics_file="${BENCHMARK_DIR}/traversal-metrics.log"
if _declared_dependency_path_exists "t1" "t999" "$graph_edges" "" "$metrics_file"; then
	printf 'FAIL: unreachable branching-graph target was reported reachable\n' >&2
	exit 1
fi
traversal_metrics=$(<"$metrics_file")
[[ "$traversal_metrics" == "nodes=19 edges=27 traversed=27" ]] || {
	printf 'FAIL: branching traversal was not bounded to unique graph elements: %s\n' "$traversal_metrics" >&2
	exit 1
}
if _declared_dependency_path_exists "t1" "t999" "$graph_edges" $'t1\n'; then
	printf 'FAIL: a pre-seen traversal start was revisited\n' >&2
	exit 1
fi
if ! _declared_dependency_path_exists "t1" "t19" "$graph_edges" $'t19\n'; then
	printf 'FAIL: a reachable pre-seen target lost target-before-seen semantics\n' >&2
	exit 1
fi
if ! _declared_dependency_path_exists "t5" "t5" "$graph_edges" $'t5\n'; then
	printf 'FAIL: identical start and target lost target-before-seen semantics\n' >&2
	exit 1
fi
printf 'Traversal: %s\n' "$traversal_metrics"

# Historical rows without dependencies must not incur full parser cost per
# edge, and nested cycle checks must inherit a complete, reusable snapshot.
history_todo="${BENCHMARK_DIR}/history-todo.md"
for ((node = 1; node <= 800; node++)); do
	printf '%s\n' "- [x] t${node} completed history" >>"$history_todo"
done
printf '%s\n' '- [ ] t901 blocked-by:t902 ref:GH#901' \
	'- [ ] t902 blocked-by:t901 ref:GH#902' >>"$history_todo"
_RELATIONSHIP_EDGE_CACHE_FILE=""
_relationship_edges_for_file "$history_todo"
[[ "$_RELATIONSHIP_EDGE_CACHE" == *'t901|t902'* && \
	"$_RELATIONSHIP_EDGE_CACHE" == *'t902|t901'* ]] || {
	printf 'FAIL: history-heavy snapshot omitted a declared edge\n' >&2
	exit 1
}
if ! _dependency_cycle_should_skip_edge t901 t902 901 902 "$history_todo"; then
	printf 'FAIL: history-heavy snapshot lost deterministic cycle detection\n' >&2
	exit 1
fi
printf 'PASS: history-heavy graph built once and preserved cycle checks\n'

# GH#37006: the pre-fix builder ran parse_task_line (~72 processes) on every
# dependency-bearing row. Keep it here as the parity reference for the
# in-process extractor; both must accept, skip and reject the same rows.
reference_declared_edges() {
	local todo_file="$1"
	local task_line="" task_id="" parsed="" key="" value="" stripped=""
	local blocked_by="" blocks="" dep_task_id="" saved_ifs=""
	stripped=$(strip_code_fences <"$todo_file") || return 1
	_relationship_active_ids_and_refs "$stripped" || return 1
	while IFS= read -r task_line; do
		[[ "$task_line" == *"blocked-by:"* || "$task_line" == *"blocks:"* ]] || continue
		[[ "$task_line" =~ ^[[:space:]]*-[[:space:]]+\[.\][[:space:]]+(t[0-9]+(\.[0-9a-z]+)*)[[:space:]] ]] || continue
		task_id="${BASH_REMATCH[1]}"
		if ! task_identity_validate "$task_id"; then
			_relationship_skip_completed_legacy_row "$task_line" "$task_id" || return 1
			continue
		fi
		if ! parsed=$(parse_task_line "$task_line"); then
			_relationship_report_parse_failure "$task_line" "$task_id" || return 1
			continue
		fi
		blocked_by=""
		blocks=""
		while IFS='=' read -r key value; do
			case "$key" in
			blocked_by) blocked_by="$value" ;;
			blocks) blocks="$value" ;;
			esac
		done <<<"$parsed"
		saved_ifs="$IFS"
		IFS=','
		for dep_task_id in $blocked_by; do
			[[ -n "$dep_task_id" && "$dep_task_id" != "$task_id" ]] || continue
			printf '%s|%s\n' "$task_id" "$dep_task_id"
		done
		for dep_task_id in $blocks; do
			[[ -n "$dep_task_id" && "$dep_task_id" != "$task_id" ]] || continue
			printf '%s|%s\n' "$dep_task_id" "$task_id"
		done
		IFS="$saved_ifs"
	done <<<"$stripped"
	return 0
}

compare_builders() {
	local label="$1"
	local todo_file="$2"
	local new_rc=0 reference_rc=0 new_edges="" reference_edges=""
	new_edges=$(_relationship_declared_edges "$todo_file" 2>/dev/null | sort) || new_rc=$?
	reference_edges=$(reference_declared_edges "$todo_file" 2>/dev/null | sort) || reference_rc=$?
	[[ "$new_rc" -eq "$reference_rc" && "$new_edges" == "$reference_edges" ]] || {
		printf 'FAIL: %s: in-process builder diverged (rc %d vs %d)\nnew:\n%s\nreference:\n%s\n' \
			"$label" "$new_rc" "$reference_rc" "$new_edges" "$reference_edges" >&2
		exit 1
	}
	return 0
}

parity_todo="${BENCHMARK_DIR}/parity-todo.md"
printf '%s\n' \
	'- [x] t1 done blocked-by:t2,GH#5,#6 blocks:t3 ref:GH#1' \
	'- [>] t2 started blocks:t4 parent:GH#9' \
	'- [-] t3 declined blocked-by:t2 parent:t1' \
	'  - [ ] t4.1 open child blocked-by:t4 blocks:t4.1 ref:GH#41' \
	'- [x] t5 completed with bad list blocked-by:t1,,t2' \
	'- [x] t6 completed with duplicate parent blocked-by:t1 parent:t1 parent:t2' \
	'- [x] t7 completed with bad dependency blocks:t7.x' \
	'- [x] t007.3 completed padded history blocked-by:t1' \
	'- [?] t8 odd checkbox completed:2026-01-01 blocks:t1' \
	'- [ ] tox0000000000000000000000000-12 namespaced row blocked-by:t1' \
	'- [ ] to0abcdefghjkmnpqrstvwxyz012-3 namespaced row blocked-by:t1,to0abcdefghjkmnpqrstvwxyz012-4' \
	'```' '- [ ] t9 fenced example blocked-by:t1' '```' >"$parity_todo"
compare_builders "mixed edge cases" "$parity_todo"
for bad_row in '- [ ] t10 open bad list blocked-by:t1,,t2' '- [ ] t11 open padded dep blocked-by:t001' \
	'- [ ] t12 open duplicate parent blocked-by:t1 parent:t1 parent:t2' '- [?] t13 odd open blocks:t1'; do
	printf '%s\n' '- [ ] t1 base ref:GH#1' "$bad_row" >"${BENCHMARK_DIR}/fail-closed-todo.md"
	compare_builders "fail-closed: ${bad_row}" "${BENCHMARK_DIR}/fail-closed-todo.md"
done
printf 'PASS: in-process dependency extractor matches parse_task_line on accept, skip and reject\n'

# 1,000 completed rows that carry dependencies: the case the history fixture
# above never exercised. The pre-fix builder needed ~72k processes here.
dependency_history_todo="${BENCHMARK_DIR}/dependency-history-todo.md"
for ((node = 2; node <= 1001; node++)); do
	printf '%s\n' "- [x] t${node} completed history blocked-by:t$((node - 1)) blocks:t$((node + 1000)) ref:GH#${node}"
done >"$dependency_history_todo"
build_started=$(date +%s)
dependency_edges=$(_relationship_declared_edges "$dependency_history_todo")
build_seconds=$(($(date +%s) - build_started))
dependency_edge_count=$(printf '%s\n' "$dependency_edges" | awk 'NF { count++ } END { print count + 0 }')
[[ "$dependency_edge_count" -eq 2000 && "$dependency_edges" == *$'t1001|t1000\n'* &&
	"$dependency_edges" == *'t2001|t1001'* ]] || {
	printf 'FAIL: dependency-bearing history lost edges (count=%s)\n' "$dependency_edge_count" >&2
	exit 1
}
[[ "$build_seconds" -lt 10 ]] || {
	printf 'FAIL: 1000 dependency-bearing history rows took %ss to build (budget 10s)\n' "$build_seconds" >&2
	exit 1
}
printf 'PASS: 1000 dependency-bearing history rows built in %ss (edges=%s)\n' "$build_seconds" "$dependency_edge_count"
printf 'PASS: 800-task relationship benchmark captured resources and progress\n'
