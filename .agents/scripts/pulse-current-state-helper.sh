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
	local review_thread_state_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR:-$HOME/.aidevops/.agent-workspace/pr-review-thread-response}"
	local active_worker_processes=""
	local worker_worktree_count="0"
	local graphql_budget_status=""
	local runtime_state_file=""
	local objective_state_file="${AIDEVOPS_OBJECTIVE_STATE_FILE:-$HOME/.aidevops/state/objective-reconciliation.json}"
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
	if [[ -f "${SCRIPT_DIR}/worker-lifecycle-common.sh" ]]; then
		# Keep worker process discovery in the shell lifecycle helper so Python
		# static-analysis checks do not flag a subprocess bridge for this metric.
		# shellcheck source=.agents/scripts/worker-lifecycle-common.sh
		source "${SCRIPT_DIR}/worker-lifecycle-common.sh" >/dev/null 2>&1 || true
		if declare -F count_active_workers >/dev/null 2>&1; then
			active_worker_processes="$(count_active_workers 2>/dev/null || true)"
		fi
	fi
	if git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		worker_worktree_count="$(git -C "$repo_path" worktree list 2>/dev/null \
			| grep -Ec 'feature/(auto-|gh-)' || true)"
	fi
	if [[ -x "${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh" ]]; then
		graphql_budget_status="$("${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh" \
			status --cached 2>/dev/null || true)"
	fi
	runtime_state_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-pulse-runtime-state.XXXXXX") || runtime_state_file=""
	local projection_status=0
	AIDEVOPS_ACTIVE_WORKER_PROCESSES="$active_worker_processes" \
		AIDEVOPS_WORKER_WORKTREE_COUNT="$worker_worktree_count" \
		AIDEVOPS_GRAPHQL_BUDGET_STATUS="$graphql_budget_status" \
		AIDEVOPS_OBJECTIVE_STATE_FILE="$objective_state_file" \
		AIDEVOPS_RUNTIME_STATE_OUTPUT="$runtime_state_file" \
		python3 "${SCRIPT_DIR}/pulse-current-state.py" \
			"$log_dir" "$repo_path" "$window_s" "$as_json" "$SCRIPT_DIR" \
			"$review_thread_state_dir" || projection_status=$?
	if [[ "$projection_status" -eq 0 && -s "$runtime_state_file" ]] && command -v node >/dev/null 2>&1; then
		node "${SCRIPT_DIR}/runtime-events.mjs" state auto "pulse:current" - <"$runtime_state_file" \
			>/dev/null 2>&1 || true
	fi
	rm -f "$runtime_state_file" 2>/dev/null || true
	return "$projection_status"
}

main "$@"
