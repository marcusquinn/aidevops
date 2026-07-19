#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23087/GH#24438: when GitHub rulesets reject the
# historical `gh pr merge --admin` path, deterministic merge first asks GitHub
# to auto-merge/queue the PR without admin bypass instead of recording another
# failed zero-progress cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""
REMEDIATION_LOG=""
MERGE_EVENT_LOG=""
_OW_LABEL_PAT=",origin:worker,"

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
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_STUB_MODE="${GH_STUB_MODE:-ruleset}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	REMEDIATION_LOG="${TEST_ROOT}/remediation.log"
	: >"$REMEDIATION_LOG"
	MERGE_EVENT_LOG="${TEST_ROOT}/merge-events.log"
	: >"$MERGE_EVENT_LOG"
	export TEST_ROOT GH_LOG REMEDIATION_LOG MERGE_EVENT_LOG

cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

mode="${GH_STUB_MODE:-ruleset}"

if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
	printf '%s\n' '{"login":"tester"}'
	exit 0
fi

if [[ "$mode" == "stale-cache-401" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	count_file="${TEST_ROOT}/merge-count.txt"
	count=0
	if [[ -f "$count_file" ]]; then
		count=$(cat "$count_file")
	fi
	count=$((count + 1))
	printf '%s\n' "$count" >"$count_file"
	if [[ "$count" -eq 1 ]]; then
		printf '%s\n' 'non-200 OK status code: 401 Unauthorized body: "{ \"message\": \"Requires authentication\" }"' >&2
		exit 1
	fi
	exit 0
fi

if [[ "$mode" == "conversation-chain" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Repository rule violations found' >&2
	printf '%s\n' 'GraphQL: A conversation must be resolved before merging' >&2
	exit 1
fi

if [[ "$mode" == "conversation-chain" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--auto"* ]]; then
	printf '%s\n' 'GraphQL: Pull request is not eligible for native auto-merge' >&2
	exit 1
fi

if [[ "$mode" == "conversation-chain" && "$1" == "pr" && "$2" == "merge" ]]; then
	printf '%s\n' 'X Pull request owner/repo#77 is not mergeable: the base branch policy prohibits the merge.' >&2
	exit 1
fi

if [[ "$mode" == "expected-check" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Required status check "review-bot-gate" is expected. (mergePullRequest)' >&2
	exit 1
fi

if [[ "$mode" == "pending-check" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Required status check "maintainer-gate" is pending. (mergePullRequest)' >&2
	exit 1
fi

if [[ ( "$mode" == "expected-check" || "$mode" == "pending-check" ) && "$1" == "pr" && "$2" == "update-branch" ]]; then
	exit 0
fi

if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Repository rule violations found' >&2
	exit 1
fi

if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--auto"* ]]; then
	exit 0
fi

if [[ "$1" == "pr" && "$2" == "merge" ]]; then
	printf '%s\n' 'X Pull request owner/repo#77 is not mergeable: the base branch policy prohibits the merge.' >&2
	exit 1
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_function_under_test() {
	local src_process
	src_process=$(awk '
		/^_process_single_ready_pr\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_process" ]]; then
		printf 'ERROR: could not extract _process_single_ready_pr from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	source "${SCRIPT_DIR}/../gh-merge-cache-remediation-lib.sh"
	# shellcheck disable=SC1090
	eval "$src_process"
	return 0
}

_pmp_normalize_mergeable_state_into() {
	local __var_name="$1"
	local __value="$2"
	printf -v "$__var_name" '%s' "$__value"
	return 0
}

_pmp_normalize_review_decision_into() {
	local __var_name="$1"
	local __value="$2"
	printf -v "$__var_name" '%s' "$__value"
	return 0
}

_pmp_review_decision_is_unknown() {
	local __value="$1"
	[[ -z "$__value" || "$__value" == "UNKNOWN" ]]
	return $?
}

PULSE_UNKNOWN_STATE="UNKNOWN"
_resolve_pr_mergeable_status() { return 0; }
_extract_linked_issue() { printf '123'; return 0; }
_check_pr_merge_gates() { return 0; }
_pr_required_checks_pass() { return 0; }
approve_collaborator_pr() { return 0; }
_check_ruleset_required_reviews_passing() { return 0; }
_extract_merge_summary() { printf 'summary'; return 0; }
_retarget_stacked_children() { return 0; }
_pulse_merge_admin_safety_check() { return 0; }
_pulse_merge_final_trust_gate() { _PULSE_FINAL_REQUIRES_SYNCHRONOUS_MERGE=0; return 0; }
_set_native_auto_merge_or_skip() { return 1; }
_repo_allows_auto_merge() { return "${REPO_ALLOWS_AUTO_MERGE_RC:-0}"; }
_attempt_existing_auto_merge_behind_update_branch() { return 1; }
_attempt_green_behind_update_branch() { return "${GREEN_BEHIND_UPDATE_RC:-1}"; }
sleep() {
	local seconds="$1"
	printf 'sleep:%s\n' "$seconds" >>"$MERGE_EVENT_LOG"
	return 0
}
_pmp_record_deterministic_progress_now() {
	local merged_count="$1"
	local progress_count="$2"
	printf 'progress:%s:%s\n' "$merged_count" "$progress_count" >>"$MERGE_EVENT_LOG"
	return 0
}
_handle_post_merge_actions() {
	printf 'post-merge\n' >>"$MERGE_EVENT_LOG"
	return 0
}
gh_pr_view() { printf '{"labels":[]}'; return 0; }

_pulse_merge_maybe_dispatch_review_thread_remediation() {
	local pr_number="$1"
	local repo_slug="$2"
	local merge_output="$3"
	printf 'pr=%s repo=%s\n%s\n' "$pr_number" "$repo_slug" "$merge_output" >>"${REMEDIATION_LOG:?}"
	return 0
}

prepare_stale_cache_fixture() {
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.cache/gh"
	cat >"${HOME}/.cache/gh/graphql-401.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/graphql"}
CACHE
	cat >"${HOME}/.cache/gh/healthy.cache" <<'CACHE'
HTTP/2.0 200 OK
{"data":{"viewer":{"login":"tester"}}}
CACHE
	return 0
}

test_ruleset_violation_enables_auto_merge_without_admin() {
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test","headRefOid":"head-current"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "ruleset violation fallback returns merged" 1 "Expected 0, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 77 --repo owner/repo --squash --admin' "$GH_LOG"; then
		print_result "ruleset violation fallback tries admin first" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 77 --repo owner/repo --auto --squash --match-head-commit head-current$' "$GH_LOG"; then
		print_result "ruleset violation fallback enables native auto-merge" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 77 --repo owner/repo --squash$' "$GH_LOG"; then
		print_result "ruleset violation fallback avoids direct policy-prohibited merge" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'evaluating protection-respecting fallbacks.*GH#24438' "$LOGFILE"; then
		print_result "ruleset violation fallback writes audit log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "ruleset violation fallback enables native auto-merge and succeeds" 0
	teardown_test_env
	return 0
}

test_ruleset_violation_skips_native_auto_merge_when_disabled() {
	REPO_ALLOWS_AUTO_MERGE_RC=1
	setup_test_env
	define_function_under_test || {
		teardown_test_env
		unset REPO_ALLOWS_AUTO_MERGE_RC
		return 0
	}

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test","headRefOid":"head-current"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -eq 3 ]] &&
		! grep -qE 'gh pr merge 77 .*--auto' "$GH_LOG" &&
		grep -qE 'gh pr merge 77 --repo owner/repo --squash --match-head-commit head-current$' "$GH_LOG" &&
		grep -qF 'native auto-merge skipped: repository does not allow auto-merge' "$LOGFILE"; then
		print_result "ruleset fallback skips native auto-merge when repository disables it" 0
	else
		print_result "ruleset fallback skips native auto-merge when repository disables it" 1 \
			"result=${result}; gh log: $(tr '\n' ';' <"$GH_LOG"); pulse log: $(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	unset REPO_ALLOWS_AUTO_MERGE_RC
	return 0
}

test_green_behind_update_defers_before_merge_attempts() {
	unset GH_STUB_MODE
	GREEN_BEHIND_UPDATE_RC=0
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GREEN_BEHIND_UPDATE_RC; return 0; }

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "green BEHIND update defers before merge attempts" 1 \
			"Expected 1, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GREEN_BEHIND_UPDATE_RC
		return 0
	fi
	if grep -qE 'gh pr merge 77' "$GH_LOG"; then
		print_result "green BEHIND update avoids admin/native/direct merge writes" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GREEN_BEHIND_UPDATE_RC
		return 0
	fi
	print_result "green BEHIND update defers before merge attempts" 0
	teardown_test_env
	unset GREEN_BEHIND_UPDATE_RC
	return 0
}

test_draft_pr_without_origin_labels_skips_merge_write() {
	unset GH_STUB_MODE
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":88,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"draft test","labels":[],"isDraft":true}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "draft PR without origin labels skips merge" 1 "Expected 1, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 88' "$GH_LOG"; then
		print_result "draft PR without origin labels makes no merge write" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'draft PR not eligible for auto-merge.*GH#23525' "$LOGFILE"; then
		print_result "draft PR without origin labels writes skip log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "draft PR without origin labels is blocked before gh pr merge" 0
	teardown_test_env
	return 0
}

test_expected_required_check_updates_branch_and_defers() {
	GH_STUB_MODE="expected-check"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 4 ]]; then
		print_result "expected required-check blocker defers after update-branch" 1 \
			"Expected 4, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	if ! grep -qE 'gh pr update-branch 77 --repo owner/repo' "$GH_LOG"; then
		print_result "expected required-check blocker invokes update-branch" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	if ! grep -qE 'expected/pending required status check.*GH#26899' "$LOGFILE"; then
		print_result "expected required-check blocker writes defer audit log" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	print_result "expected required-check blocker updates branch and defers" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_pending_required_check_updates_branch_and_defers() {
	GH_STUB_MODE="pending-check"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 4 ]]; then
		print_result "pending required-check blocker defers after update-branch" 1 \
			"Expected 4, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	if ! grep -qE 'gh pr update-branch 77 --repo owner/repo' "$GH_LOG"; then
		print_result "pending required-check blocker invokes update-branch" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	print_result "pending required-check blocker updates branch and defers" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_stale_cache_401_retries_admin_merge_once() {
	GH_STUB_MODE="stale-cache-401"
	setup_test_env
	prepare_stale_cache_fixture
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "stale cache 401 retries admin merge" 1 "Expected 0, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	local merge_count="0"
	[[ -f "${TEST_ROOT}/merge-count.txt" ]] && merge_count=$(cat "${TEST_ROOT}/merge-count.txt")
	if [[ "$merge_count" != "2" ]]; then
		print_result "stale cache 401 retries admin merge exactly once" 1 "merge_count=${merge_count}; gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	local merge_events=""
	merge_events=$(tr '\n' ' ' <"$MERGE_EVENT_LOG")
	if [[ "$merge_events" != "progress:1:0 sleep:1 post-merge " ]]; then
		print_result "successful merge records recovery before interruptible post-merge work" 1 \
			"event order: ${merge_events:-none}"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	print_result "successful merge records recovery before interruptible post-merge work" 0

	if [[ -f "${HOME}/.cache/gh/graphql-401.cache" ]] || \
		! find "${HOME}/.cache/gh" -path '*/aidevops-quarantine-*/*graphql-401.cache*' -type f | grep -q .; then
		print_result "stale cache 401 quarantines only matching cache file" 1 "cache remediation did not quarantine stale 401 file"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if [[ ! -f "${HOME}/.cache/gh/healthy.cache" ]]; then
		print_result "stale cache 401 preserves healthy cache file" 1 "healthy cache file was moved"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qE 'quarantined 1 stale gh HTTP 401 cache file' "$LOGFILE"; then
		print_result "stale cache 401 writes remediation audit log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	print_result "stale cache 401 retries admin merge once and succeeds" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_ruleset_fallback_failure_preserves_admin_conversation_context() {
	GH_STUB_MODE="conversation-chain"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 3 ]]; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"Expected 3, got ${result}; log: $(tr '\n' ';' <"$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qF 'A conversation must be resolved' "$REMEDIATION_LOG"; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"remediation did not receive admin blocker: $(tr '\n' ';' <"$REMEDIATION_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qF '[native auto-merge fallback]' "$REMEDIATION_LOG" \
		|| ! grep -qF '[direct merge fallback]' "$REMEDIATION_LOG"; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"remediation did not receive accumulated fallback attempts: $(tr '\n' ';' <"$REMEDIATION_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qF 'A conversation must be resolved' "$LOGFILE"; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"final failure log did not retain admin blocker: $(tr '\n' ';' <"$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	print_result "fallback-chain failure preserves admin conversation context" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

main() {
	test_ruleset_violation_enables_auto_merge_without_admin
	test_ruleset_violation_skips_native_auto_merge_when_disabled
	test_green_behind_update_defers_before_merge_attempts
	test_draft_pr_without_origin_labels_skips_merge_write
	test_expected_required_check_updates_branch_and_defers
	test_pending_required_check_updates_branch_and_defers
	test_stale_cache_401_retries_admin_merge_once
	test_ruleset_fallback_failure_preserves_admin_conversation_context

	printf '\n=================================\n'
	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	printf '=================================\n'

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
