#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
PS_MOCK_OUTPUT=""
GH_ISSUE_LIST_JSON="[]"
GH_PR_LIST_JSON="[]"
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

ps() {
	printf '%s\n' "$PS_MOCK_OUTPUT"
	return 0
}

gh() {
	if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
		printf '%s\n' "$GH_ISSUE_LIST_JSON"
		return 0
	fi

	if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
		printf '%s\n' "$GH_PR_LIST_JSON"
		return 0
	fi

	if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
		printf 'owner\n'
		return 0
	fi

	printf 'unsupported gh invocation in test stub\n' >&2
	return 1
}

run_count() {
	local mock_output="$1"
	PS_MOCK_OUTPUT="$mock_output"
	count_active_workers
	return 0
}

test_counts_workers_and_ignores_supervisor_session() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101 mentions /pulse\" \"/full-loop Implement issue #101 -- pulse reliability\"
/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse state includes /full-loop markers\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "2" ]]; then
		print_result "counts full-loop workers without broad /pulse exclusions" 0
		return 0
	fi

	print_result "counts full-loop workers without broad /pulse exclusions" 1 "Expected 2 active workers, got '${output}'"
	return 0
}

test_returns_zero_when_no_full_loop_workers() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "0" ]]; then
		print_result "returns zero when no matching workers exist" 0
		return 0
	fi

	print_result "returns zero when no matching workers exist" 1 "Expected 0 active workers, got '${output}'"
	return 0
}

test_does_not_exclude_non_supervisor_role_pulse_commands() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key another-session --dir /repo-a --title \"Issue #200\" \"/full-loop Implement issue #200\"")

	if [[ "$output" == "1" ]]; then
		print_result "keeps non-supervisor role pulse commands countable" 0
		return 0
	fi

	print_result "keeps non-supervisor role pulse commands countable" 1 "Expected 1 active worker, got '${output}'"
	return 0
}

# Fix #1 & #2: prefetch_active_workers must use the same filter as count_active_workers
# so the snapshot count is consistent with the global capacity counter and the
# supervisor pulse is excluded via token-boundary matching (not substring grep).
test_prefetch_active_workers_excludes_supervisor() {
	PS_MOCK_OUTPUT="1 00:01 /usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
2 00:02 /usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse state includes /full-loop markers\"
3 00:03 /usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\""

	local prefetch_out
	prefetch_out=$(prefetch_active_workers 2>/dev/null)

	# Supervisor pulse must not appear in the snapshot
	if echo "$prefetch_out" | grep -q 'supervisor-pulse'; then
		print_result "prefetch_active_workers excludes supervisor pulse" 1 \
			"Supervisor pulse appeared in prefetch output"
		return 0
	fi

	# Both worker PIDs (1 and 3) must appear
	if echo "$prefetch_out" | grep -q 'PID 1' && echo "$prefetch_out" | grep -q 'PID 3'; then
		print_result "prefetch_active_workers excludes supervisor pulse" 0
		return 0
	fi

	print_result "prefetch_active_workers excludes supervisor pulse" 1 \
		"Expected PIDs 1 and 3 in prefetch output, got: $(echo "$prefetch_out" | grep 'PID' || echo 'none')"
	return 0
}

test_prefetch_active_workers_consistent_with_count() {
	PS_MOCK_OUTPUT="1 00:01 /usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
2 00:02 /usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse\"
3 00:03 /usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\""

	local count_out prefetch_worker_count
	count_out=$(count_active_workers)
	prefetch_worker_count=$(prefetch_active_workers 2>/dev/null | grep -c '^- PID' || echo "0")

	if [[ "$count_out" == "$prefetch_worker_count" ]]; then
		print_result "prefetch_active_workers count matches count_active_workers" 0
		return 0
	fi

	print_result "prefetch_active_workers count matches count_active_workers" 1 \
		"count_active_workers=${count_out}, prefetch worker lines=${prefetch_worker_count}"
	return 0
}

# Fix #3: has_worker_for_repo_issue must use exact --dir matching to prevent
# sibling-path false positives (e.g. /tmp/aidevops matching /tmp/aidevops-tools).
test_has_worker_exact_dir_match_no_sibling_false_positive() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/aidevops","pulse":true}]}\n' \
		>"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	# Sibling repo path — must NOT match
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /tmp/aidevops-tools --title \"Issue #42\" \"/full-loop Implement issue #42\""

	if has_worker_for_repo_issue "42" "owner/repo"; then
		print_result "has_worker_for_repo_issue rejects sibling-path match" 1 \
			"Sibling path /tmp/aidevops-tools incorrectly matched repo /tmp/aidevops"
		return 0
	fi

	print_result "has_worker_for_repo_issue rejects sibling-path match" 0
	return 0
}

test_has_worker_exact_dir_match_accepts_correct_path() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/aidevops","pulse":true}]}\n' \
		>"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	# Exact repo path — must match
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /tmp/aidevops --title \"Issue #42\" \"/full-loop Implement issue #42\""

	if has_worker_for_repo_issue "42" "owner/repo"; then
		print_result "has_worker_for_repo_issue accepts exact path match" 0
		return 0
	fi

	print_result "has_worker_for_repo_issue accepts exact path match" 1 \
		"Exact path /tmp/aidevops was not matched"
	return 0
}

test_counts_review_issue_pr_workers() {
	# GH#12374: /review-issue-pr workers must be counted alongside /full-loop workers.
	local output
	output=$(run_count "/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #300\" \"/review-issue-pr Review issue #300\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #301\" \"/full-loop Implement issue #301\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Issue #302\" \"/review-issue-pr Review issue #302\"")

	if [[ "$output" == "3" ]]; then
		print_result "counts /review-issue-pr workers alongside /full-loop (GH#12374)" 0
		return 0
	fi

	print_result "counts /review-issue-pr workers alongside /full-loop (GH#12374)" 1 "Expected 3 active workers, got '${output}'"
	return 0
}

test_list_dispatchable_candidates_default_open_except_needs_labels() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"priority:high"}]},
	  {"number":2,"title":"owner assigned","updatedAt":"2026-03-31T00:01:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"quality-debt"}]},
	  {"number":3,"title":"maintainer assigned","updatedAt":"2026-03-31T00:02:00Z","assignees":[{"login":"maintainer-bot"}],"labels":[{"name":"simplification-debt"}]},
	  {"number":4,"title":"runner assigned","updatedAt":"2026-03-31T00:03:00Z","assignees":[{"login":"other-runner"}],"labels":[{"name":"priority:high"}]},
	  {"number":5,"title":"owner queued","updatedAt":"2026-03-31T00:04:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"status:queued"}]},
	  {"number":6,"title":"needs review","updatedAt":"2026-03-31T00:05:00Z","assignees":[],"labels":[{"name":"needs-maintainer-review"}]},
	  {"number":7,"title":"needs docs","updatedAt":"2026-03-31T00:06:00Z","assignees":[],"labels":[{"name":"needs-docs"}]},
	  {"number":8,"title":"supervisor telemetry","updatedAt":"2026-03-31T00:07:00Z","assignees":[],"labels":[{"name":"supervisor"}]},
	  {"number":9,"title":"in progress but runnable","updatedAt":"2026-03-31T00:08:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"status:in-progress"}]}
	]'
	GH_PR_LIST_JSON='[]'

	local output
	output=$(list_dispatchable_issue_candidates "owner/repo" 100)

	if [[ "$output" == *$'1|unassigned'* && "$output" == *$'2|owner assigned'* && "$output" == *$'3|maintainer assigned'* && "$output" == *$'4|runner assigned'* && "$output" == *$'5|owner queued'* && "$output" == *$'9|in progress but runnable'* && "$output" != *$'6|needs review'* && "$output" != *$'7|needs docs'* && "$output" != *$'8|supervisor telemetry'* ]]; then
		print_result "list_dispatchable_issue_candidates is default-open except needs-*" 0
		return 0
	fi

	print_result "list_dispatchable_issue_candidates is default-open except needs-*" 1 "Unexpected candidate set: ${output}"
	return 0
}

test_count_runnable_candidates_counts_default_open_backlog() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[]},
	  {"number":2,"title":"owner assigned","updatedAt":"2026-03-31T00:01:00Z","assignees":[{"login":"owner"}],"labels":[]},
	  {"number":3,"title":"maintainer assigned","updatedAt":"2026-03-31T00:02:00Z","assignees":[{"login":"maintainer-bot"}],"labels":[]},
	  {"number":4,"title":"runner assigned","updatedAt":"2026-03-31T00:03:00Z","assignees":[{"login":"other-runner"}],"labels":[]}
	]'
	GH_PR_LIST_JSON='[
	  {"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[]},
	  {"reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"FAILURE"}]}
	]'

	local count
	count=$(count_runnable_candidates)

	if [[ "$count" == "6" ]]; then
		print_result "count_runnable_candidates counts default-open backlog" 0
		return 0
	fi

	print_result "count_runnable_candidates counts default-open backlog" 1 "Expected 6 runnable items, got '${count}'"
	return 0
}

test_count_runnable_candidates_keeps_stdout_numeric_with_debug() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[]}
	]'
	GH_PR_LIST_JSON='[
	  {"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[]}
	]'

	local count stderr_file
	stderr_file="${TEST_ROOT}/count-runnable-debug.stderr"
	PULSE_DEBUG=1 count=$(count_runnable_candidates 2>"$stderr_file")

	if [[ "$count" == "2" ]] && grep -q 'count_runnable_candidates repo=owner/repo issues=1 prs=1 total=2' "$stderr_file"; then
		print_result "count_runnable_candidates keeps stdout numeric with debug enabled" 0
		return 0
	fi

	print_result "count_runnable_candidates keeps stdout numeric with debug enabled" 1 \
		"Expected numeric stdout 2 with stderr debug log; got count='${count}', stderr='$(tr '\n' '|' <"$stderr_file")'"
	return 0
}

test_count_queued_without_worker_keeps_stdout_numeric_with_debug() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":11,"assignees":[]}
	]'
	has_worker_for_repo_issue() {
		return 1
	}

	local count stderr_file
	stderr_file="${TEST_ROOT}/count-queued-debug.stderr"
	PULSE_DEBUG=1 count=$(count_queued_without_worker 2>"$stderr_file")
	unset -f has_worker_for_repo_issue

	if [[ "$count" == "1" ]] && grep -q 'count_queued_without_worker repo=owner/repo queued=1' "$stderr_file" && grep -q 'count_queued_without_worker repo=owner/repo issue=11 missing_worker=true' "$stderr_file"; then
		print_result "count_queued_without_worker keeps stdout numeric with debug enabled" 0
		return 0
	fi

	print_result "count_queued_without_worker keeps stdout numeric with debug enabled" 1 \
		"Expected numeric stdout 1 with stderr debug logs; got count='${count}', stderr='$(tr '\n' '|' <"$stderr_file")'"
	return 0
}

test_queue_governor_enters_merge_heavy_at_critical_backlog() {
	STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
	QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
	: >"$STATE_FILE"
	printf '12\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Issue #102\" \"/full-loop Implement issue #102\""

	_compute_queue_governor_guidance 180 40 12 8

	local state_text
	state_text=$(<"$STATE_FILE")
	if [[ "$state_text" == *"PULSE_QUEUE_MODE=merge-heavy"* && "$state_text" == *"PULSE_PR_BACKLOG_BAND=critical"* && "$state_text" == *"NEW_ISSUE_DISPATCH_PCT=10"* && "$state_text" == *"PULSE_WORKER_UTILIZATION_PCT=25"* ]]; then
		print_result "queue governor enters merge-heavy at critical backlog" 0
		return 0
	fi

	print_result "queue governor enters merge-heavy at critical backlog" 1 "Unexpected governor output: ${state_text}"
	return 0
}

test_queue_governor_enters_pr_heavy_at_heavy_backlog() {
	STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
	QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
	: >"$STATE_FILE"
	printf 'prev_total_prs=80\nprev_total_issues=110\nprev_ready_prs=4\nprev_failing_prs=10\nprev_recorded_at=1\n' >"$QUEUE_METRICS_FILE"
	printf '8\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #200\" \"/full-loop Implement issue #200\""

	_compute_queue_governor_guidance 110 120 3 28

	local state_text
	state_text=$(<"$STATE_FILE")
	if [[ "$state_text" == *"PULSE_QUEUE_MODE=pr-heavy"* && "$state_text" == *"PULSE_PR_BACKLOG_BAND=heavy"* && "$state_text" == *"PR_REMEDIATION_FOCUS_PCT=75"* && "$state_text" == *"NEW_ISSUE_DISPATCH_PCT=25"* ]]; then
		print_result "queue governor enters pr-heavy at heavy backlog" 0
		return 0
	fi

	print_result "queue governor enters pr-heavy at heavy backlog" 1 "Unexpected governor output: ${state_text}"
	return 0
}

test_queue_governor_reports_drain_rate_telemetry() {
	STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
	QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
	: >"$STATE_FILE"
	local now_epoch previous_epoch
	now_epoch=$(date +%s)
	previous_epoch=$((now_epoch - 1800))
	printf 'prev_total_prs=120\nprev_total_issues=80\nprev_ready_prs=8\nprev_failing_prs=18\nprev_recorded_at=%s\n' "$previous_epoch" >"$QUEUE_METRICS_FILE"
	printf '6\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #300\" \"/full-loop Implement issue #300\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #301\" \"/full-loop Implement issue #301\""

	_compute_queue_governor_guidance 114 82 6 16

	local state_text
	state_text=$(<"$STATE_FILE")
	if [[ "$state_text" == *"OPEN_PR_DRAIN_PER_CYCLE=6"* && "$state_text" == *"ESTIMATED_MERGE_DRAIN_PER_HOUR=12"* && "$state_text" == *"PULSE_ACTIVE_WORKERS=2"* && "$state_text" == *"PULSE_MAX_WORKERS=6"* && "$state_text" == *"PULSE_WORKER_UTILIZATION_PCT=33"* ]]; then
		print_result "queue governor reports drain rate telemetry" 0
		return 0
	fi

	print_result "queue governor reports drain rate telemetry" 1 "Unexpected telemetry output: ${state_text}"
	return 0
}

# ─── dispatch_triage_reviews tests (GH#15655) ────────────────────────────────
#
# These tests exercise the full parse → resolve → dispatch path of
# dispatch_triage_reviews() without spawning real workers.  headless-runtime-
# helper.sh is stubbed so no external processes are launched.
#
# Key regressions guarded:
#   #15614 — function never called (ordering bug, not tested here)
#   #15617 — grep -P (GNU-only), state-file format mismatch, wrong jq path
#   #15631 — head -n -2 (GNU-only) in model-availability-helper.sh
#   #15636 — ${model_args[@]} unbound variable under set -u

# Stub headless-runtime-helper.sh so dispatch_triage_reviews does not launch
# real workers.  Records each invocation in DISPATCH_LOG for assertion.
DISPATCH_LOG=""

headless_runtime_helper_stub() {
	# Capture the --session-key value to confirm which issue was dispatched.
	local session_key=""
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == "--session-key" ]]; then
			session_key="${2:-}"
			shift 2
		else
			shift
		fi
	done
	DISPATCH_LOG="${DISPATCH_LOG}${session_key}"$'\n'
	return 0
}

# Redirect the helper path used inside dispatch_triage_reviews to our stub.
# We override the function that pulse-wrapper.sh calls by shadowing the
# absolute path with a shell function of the same basename, then patching
# the call via PATH prepend.
_setup_dispatch_stub() {
	local stub_dir="${TEST_ROOT}/stubs"
	mkdir -p "$stub_dir"
	# Write a stub script that appends the session-key to DISPATCH_LOG.
	printf '#!/usr/bin/env bash\n' >"${stub_dir}/headless-runtime-helper.sh"
	printf 'session_key=""\n' >>"${stub_dir}/headless-runtime-helper.sh"
	printf 'while [[ $# -gt 0 ]]; do\n' >>"${stub_dir}/headless-runtime-helper.sh"
	# shellcheck disable=SC2016
	printf '  if [[ "$1" == "--session-key" ]]; then session_key="${2:-}"; shift 2; else shift; fi\n' >>"${stub_dir}/headless-runtime-helper.sh"
	printf 'done\n' >>"${stub_dir}/headless-runtime-helper.sh"
	# shellcheck disable=SC2016
	printf 'printf "%%s\\n" "$session_key" >> "${DISPATCH_LOG_FILE}"\n' >>"${stub_dir}/headless-runtime-helper.sh"
	chmod +x "${stub_dir}/headless-runtime-helper.sh"
	export PATH="${stub_dir}:${PATH}"
	# Override HEADLESS_RUNTIME_HELPER so dispatch_triage_reviews uses the stub
	# instead of the absolute path set when pulse-wrapper.sh was sourced.
	export HEADLESS_RUNTIME_HELPER="${stub_dir}/headless-runtime-helper.sh"
	export DISPATCH_LOG_FILE="${TEST_ROOT}/dispatch.log"
	: >"$DISPATCH_LOG_FILE"
	return 0
}

_make_repos_json() {
	local slug="$1"
	local path="$2"
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"%s","path":"%s","pulse":true}]}\n' \
		"$slug" "$path" >"$repos_json_path"
	printf '%s\n' "$repos_json_path"
	return 0
}

_make_state_file() {
	local state_path="${TEST_ROOT}/pulse-state.txt"
	printf '%s' "$1" >"$state_path"
	printf '%s\n' "$state_path"
	return 0
}

# ── Test 1: slot count decremented for each dispatched triage review ──────────
test_dispatch_triage_reviews_decrements_slot_count() {
	DISPATCH_LOG_FILE="${TEST_ROOT}/dispatch-t1.log"
	: >"$DISPATCH_LOG_FILE"

	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #100: Fix login bug [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
- Issue #101: Add dark mode [status: **needs-review**] [created: 2026-01-02T00:00:00Z]
- Issue #102: Already reviewed [status: **reviewed**] [created: 2026-01-03T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	# model-availability-helper.sh is not available in test env; resolved_model
	# will be empty, which exercises the no-model branch (same as production
	# when all models are rate-limited).
	local remaining
	remaining=$(dispatch_triage_reviews 5 "$repos_json" 2>/dev/null)

	# 2 needs-review issues dispatched → 5 - 2 = 3 remaining
	if [[ "$remaining" == "3" ]]; then
		print_result "dispatch_triage_reviews decrements slot count for each dispatch" 0
		return 0
	fi

	print_result "dispatch_triage_reviews decrements slot count for each dispatch" 1 \
		"Expected remaining=3, got '${remaining}'"
	return 0
}

# ── Test 2: no stderr errors (catches GNU grep -P / head -n -N regressions) ───
test_dispatch_triage_reviews_no_stderr_errors() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #200: Needs triage [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local stderr_file="${TEST_ROOT}/triage-stderr.txt"
	dispatch_triage_reviews 3 "$repos_json" 2>"$stderr_file" >/dev/null

	local stderr_content
	stderr_content=$(<"$stderr_file")

	# Fail if any of the known macOS-incompatible error strings appear.
	if [[ "$stderr_content" == *"illegal line count"* ]]; then
		print_result "dispatch_triage_reviews produces no 'illegal line count' stderr (head -n -N)" 1 \
			"stderr: ${stderr_content}"
		return 0
	fi
	if [[ "$stderr_content" == *"unbound variable"* ]]; then
		print_result "dispatch_triage_reviews produces no 'unbound variable' stderr (set -u)" 1 \
			"stderr: ${stderr_content}"
		return 0
	fi
	if [[ "$stderr_content" == *"invalid option"* && "$stderr_content" == *"grep"* ]]; then
		print_result "dispatch_triage_reviews produces no grep -P stderr (GNU-only flag)" 1 \
			"stderr: ${stderr_content}"
		return 0
	fi

	print_result "dispatch_triage_reviews produces no macOS-incompatible stderr errors" 0
	return 0
}

# ── Test 3: returns available unchanged when no needs-review entries ──────────
test_dispatch_triage_reviews_returns_available_when_no_candidates() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #300: Already done [status: **reviewed**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 4 "$repos_json" 2>/dev/null)

	if [[ "$remaining" == "4" ]]; then
		print_result "dispatch_triage_reviews returns available unchanged when no candidates" 0
		return 0
	fi

	print_result "dispatch_triage_reviews returns available unchanged when no candidates" 1 \
		"Expected remaining=4, got '${remaining}'"
	return 0
}

# ── Test 4: caps dispatches at triage_max=2 even with more candidates ─────────
test_dispatch_triage_reviews_caps_at_triage_max() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #400: First [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
- Issue #401: Second [status: **needs-review**] [created: 2026-01-02T00:00:00Z]
- Issue #402: Third [status: **needs-review**] [created: 2026-01-03T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 10 "$repos_json" 2>/dev/null)

	# triage_max=2, so only 2 dispatched → 10 - 2 = 8
	if [[ "$remaining" == "8" ]]; then
		print_result "dispatch_triage_reviews caps dispatches at triage_max=2" 0
		return 0
	fi

	print_result "dispatch_triage_reviews caps dispatches at triage_max=2" 1 \
		"Expected remaining=8 (capped at 2 dispatches), got '${remaining}'"
	return 0
}

# ── Test 5: returns available=0 unchanged when no slots ──────────────────────
test_dispatch_triage_reviews_returns_zero_when_no_slots() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #500: Needs triage [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 0 "$repos_json" 2>/dev/null)

	if [[ "$remaining" == "0" ]]; then
		print_result "dispatch_triage_reviews returns 0 when no slots available" 0
		return 0
	fi

	print_result "dispatch_triage_reviews returns 0 when no slots available" 1 \
		"Expected remaining=0, got '${remaining}'"
	return 0
}

# ── Test 6: jq path uses .initialized_repos[] not .[] ────────────────────────
# Regression for #15617 bug 4: wrong jq path caused path lookup to return empty,
# so no workers were dispatched even when candidates existed.
test_dispatch_triage_reviews_resolves_repo_path_via_initialized_repos() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	# Use the correct .initialized_repos[] structure; a flat .[] would fail.
	printf '{"initialized_repos":[{"slug":"owner/myrepo","path":"/tmp/myrepo","pulse":true}]}\n' \
		>"$repos_json_path"

	local state_file
	state_file=$(_make_state_file "## owner/myrepo

- Issue #600: Needs triage [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 3 "$repos_json_path" 2>/dev/null)

	# Path resolved correctly → 1 dispatch → 3 - 1 = 2
	if [[ "$remaining" == "2" ]]; then
		print_result "dispatch_triage_reviews resolves repo path via .initialized_repos[] (not .[])" 0
		return 0
	fi

	print_result "dispatch_triage_reviews resolves repo path via .initialized_repos[] (not .[])" 1 \
		"Expected remaining=2 (1 dispatch), got '${remaining}' — likely jq path bug"
	return 0
}

# ── Test 7: returns available unchanged when state file is missing ────────────
test_dispatch_triage_reviews_returns_available_when_no_state_file() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	# Clear TRIAGE_STATE_FILE so the function falls back to deriving from STATE_FILE.
	TRIAGE_STATE_FILE=""
	STATE_FILE="/nonexistent/state-file-that-does-not-exist.txt"
	local remaining
	remaining=$(dispatch_triage_reviews 7 "$repos_json" 2>/dev/null)

	if [[ "$remaining" == "7" ]]; then
		print_result "dispatch_triage_reviews returns available unchanged when state file missing" 0
		return 0
	fi

	print_result "dispatch_triage_reviews returns available unchanged when state file missing" 1 \
		"Expected remaining=7, got '${remaining}'"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	_setup_dispatch_stub

	test_counts_workers_and_ignores_supervisor_session
	test_returns_zero_when_no_full_loop_workers
	test_does_not_exclude_non_supervisor_role_pulse_commands
	test_prefetch_active_workers_excludes_supervisor
	test_prefetch_active_workers_consistent_with_count
	test_has_worker_exact_dir_match_no_sibling_false_positive
	test_has_worker_exact_dir_match_accepts_correct_path
	test_counts_review_issue_pr_workers
	test_list_dispatchable_candidates_default_open_except_needs_labels
	test_count_runnable_candidates_counts_default_open_backlog
	test_count_runnable_candidates_keeps_stdout_numeric_with_debug
	test_count_queued_without_worker_keeps_stdout_numeric_with_debug
	test_queue_governor_enters_merge_heavy_at_critical_backlog
	test_queue_governor_enters_pr_heavy_at_heavy_backlog
	test_queue_governor_reports_drain_rate_telemetry
	test_dispatch_triage_reviews_decrements_slot_count
	test_dispatch_triage_reviews_no_stderr_errors
	test_dispatch_triage_reviews_returns_available_when_no_candidates
	test_dispatch_triage_reviews_caps_at_triage_max
	test_dispatch_triage_reviews_returns_zero_when_no_slots
	test_dispatch_triage_reviews_resolves_repo_path_via_initialized_repos
	test_dispatch_triage_reviews_returns_available_when_no_state_file

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
