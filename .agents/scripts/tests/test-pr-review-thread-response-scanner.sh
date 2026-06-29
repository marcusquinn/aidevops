#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)/pr-review-thread-response-scanner.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

write_fake_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" && "${2:-}" == "rate_limit" ]]; then
	printf '%s\n' "${STUB_GRAPHQL_REMAINING:-100}"
	exit 0
fi
if [[ "$1" == "pr" && "${2:-}" == "list" ]]; then
	printf '%s\n' "${STUB_PR_LIST:-1	Fix active PR	false	origin:worker	feature/review	worker-bot}"
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "graphql" ]]; then
	for arg in "$@"; do
		if [[ "$arg" == "owner=" || "$arg" == "name=" ]]; then
			printf 'empty repo GraphQL field: %s\n' "$arg" >&2
			exit 1
		fi
	done
	if [[ "$*" == *"addPullRequestReviewThreadReply"* ]]; then
		for arg in "$@"; do
			if [[ "$arg" == body=* ]]; then
				printf '%s' "${arg#body=}" >"${GRAPHQL_BODY_CAPTURE:-/dev/null}"
			fi
		done
		printf 'reply\n' >>"${GRAPHQL_MUTATIONS_LOG:-/dev/null}"
		printf '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"COMMENT1","url":"https://example.invalid/reply"}}}}\n'
		exit 0
	fi
	if [[ "$*" == *"resolveReviewThread"* ]]; then
		printf 'resolve\n' >>"${GRAPHQL_MUTATIONS_LOG:-/dev/null}"
		printf '{"data":{"resolveReviewThread":{"thread":{"id":"THREAD1","isResolved":true}}}}\n'
		exit 0
	fi
	if [[ "$*" == *"node(id:"* && "$*" == *"comments(first: 1)"* ]]; then
		if [[ "${STUB_THREAD_AUTHOR_MODE:-ok}" == "missing" ]]; then
			printf '{"data":{"node":{"comments":{"nodes":[{"author":null}]}}}}\n'
		else
			printf '{"data":{"node":{"comments":{"nodes":[{"author":{"login":"%s"}}]}}}}\n' "${STUB_THREAD_AUTHOR_LOGIN:-reviewer}"
		fi
		exit 0
	fi
	if [[ "$*" == *"node(id:"* || "$*" == *"comments(first: 100)"* ]]; then
		printf '{"data":{"node":{"comments":{"nodes":[]}}}}\n'
		exit 0
	fi
	case "${STUB_THREADS_MODE:-unresolved}" in
	rate_limit|error)
		printf 'GraphQL failure\n' >&2
		exit 1
		;;
	none)
		printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\n'
		;;
	human)
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD_HUMAN","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"maintainer"},"path":"script.sh","line":12,"url":"https://example.invalid/human","updatedAt":"2026-06-03T00:00:00Z"}]}},{"id":"THREAD_BOT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"bot.sh","line":3,"url":"https://example.invalid/bot","updatedAt":"2026-06-03T00:00:00Z"}]}}]}}}}}'
		;;
	outdated)
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD_OLD","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"old.sh","line":7,"url":"https://example.invalid/outdated","updatedAt":"2026-06-03T00:00:00Z"}]}}]}}}}}'
		;;
	*)
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"},"path":".agents/scripts/example.sh","line":42,"url":"https://example.invalid/thread","updatedAt":"2026-06-03T00:00:00Z"}]}},{"id":"THREAD2","isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"old.sh","line":1,"url":"https://example.invalid/resolved","updatedAt":"2026-06-03T00:00:00Z"}]}}]}}}}}'
		;;
	esac
	exit 0
fi
printf '[]\n'
exit 0
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

setup_test_env() {
	unset STUB_PR_LIST STUB_THREADS_MODE
	TEST_ROOT="$(mktemp -d -t prrts.XXXXXX)"
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${TEST_ROOT}/scanner.log"
	export AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR="${TEST_ROOT}/state"
	export HEADLESS_LOG="${TEST_ROOT}/headless.log"
	export HEADLESS_PROMPT_CAPTURE="${TEST_ROOT}/prompt.md"
	mkdir -p "${HOME}" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo" "${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}"
	write_fake_gh_stub
	cat >"${TEST_ROOT}/headless-runtime-helper.sh" <<'HEADLESS_STUB'
#!/usr/bin/env bash
prompt_file=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--prompt-file)
		prompt_file="${2:-}"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
printf '%s\n' "${prompt_file}" >>"${HEADLESS_LOG}"
if [[ -n "$prompt_file" && -f "$prompt_file" ]]; then
	cp "$prompt_file" "${HEADLESS_PROMPT_CAPTURE}"
fi
exit 0
HEADLESS_STUB
	chmod +x "${TEST_ROOT}/headless-runtime-helper.sh"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-runtime-helper.sh"
	export GRAPHQL_MUTATIONS_LOG="${TEST_ROOT}/graphql-mutations.log"
	export GRAPHQL_BODY_CAPTURE="${TEST_ROOT}/graphql-body.txt"
	export PR_REVIEW_THREAD_RESPONSE_COOLDOWN=3600
	: >"$GRAPHQL_MUTATIONS_LOG"
	: >"$GRAPHQL_BODY_CAPTURE"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

wait_for_headless_log() {
	local attempts=0
	while [[ "$attempts" -lt 10 ]]; do
		if [[ -s "$HEADLESS_LOG" ]]; then
			return 0
		fi
		sleep 1
		attempts=$((attempts + 1))
	done
	return 1
}

test_scan_finds_unresolved_bot_thread() {
	setup_test_env
	local output=""
	output="$($SCANNER scan owner/repo "${TEST_ROOT}/repo")"
	if [[ "$output" == *$'1\t1\t'* && "$output" == *"gemini-code-assist"* ]]; then
		print_result "scan finds unresolved bot review thread" 0
	else
		print_result "scan finds unresolved bot review thread" 1 "output=${output}"
	fi
	teardown_test_env
	return 0
}

test_scan_skips_draft_prs() {
	setup_test_env
	export STUB_PR_LIST=$'2\tDraft PR\ttrue\torigin:worker\tfeature/draft\tworker-bot'
	local output=""
	output="$($SCANNER scan owner/repo "${TEST_ROOT}/repo")"
	if [[ -z "$output" ]]; then
		print_result "scan skips draft PRs" 0
	else
		print_result "scan skips draft PRs" 1 "output=${output}"
	fi
	teardown_test_env
	return 0
}

test_scan_includes_outdated_unresolved_threads() {
	setup_test_env
	export STUB_THREADS_MODE="outdated"
	local output=""
	output="$($SCANNER scan owner/repo "${TEST_ROOT}/repo")"
	if [[ "$output" == *"THREAD_OLD"* && "$output" == *"(outdated)"* ]]; then
		print_result "scan includes unresolved outdated bot thread" 0
	else
		print_result "scan includes unresolved outdated bot thread" 1 "output=${output}"
	fi
	teardown_test_env
	return 0
}

test_scan_pr_excludes_human_threads_by_default() {
	setup_test_env
	export STUB_THREADS_MODE="human"
	local output=""
	output="$($SCANNER scan-pr owner/repo 1)"
	if [[ "$output" == *"THREAD_BOT"* && "$output" != *"THREAD_HUMAN"* ]]; then
		print_result "scan-pr keeps human review threads excluded by default" 0
	else
		print_result "scan-pr keeps human review threads excluded by default" 1 "output=${output}"
	fi
	teardown_test_env
	return 0
}

test_scan_pr_can_include_human_threads_with_opt_in() {
	setup_test_env
	export STUB_THREADS_MODE="human"
	local output=""
	output="$(PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true $SCANNER scan-pr owner/repo 1)"
	if [[ "$output" == *"THREAD_HUMAN"* && "$output" == *"THREAD_BOT"* && "$output" == *$'1\t2\t'* ]]; then
		print_result "scan-pr includes human review threads only with opt-in" 0
	else
		print_result "scan-pr includes human review threads only with opt-in" 1 "output=${output}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_launches_worker_and_writes_state() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ -s "$HEADLESS_LOG" && -f "$state_file" ]] && grep -q 'Do not use blanket auto-resolution scripts' "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null; then
		print_result "dispatch launches bounded worker and writes state" 0
	else
		print_result "dispatch launches bounded worker and writes state" 1 "headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), state=${state_file}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_prompt_uses_framework_script_path() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	if grep -q "${SCANNER} reply" "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null && grep -q "${SCANNER} resolve" "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null; then
		print_result "dispatch prompt uses framework scanner path" 0
	else
		print_result "dispatch prompt uses framework scanner path" 1 "prompt=$(tr '\n' ' ' <"$HEADLESS_PROMPT_CAPTURE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_prompt_mentions_graphql_only_thread_operations() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	if grep -q 'Review-thread read/reply/resolve operations are GraphQL-only' "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null && \
		grep -q 'resolveReviewThread' "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null && \
		grep -q 'has no REST endpoint' "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null && \
		grep -q 'Completion requires each verified-addressed thread to be resolved' "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null; then
		print_result "dispatch prompt explains GraphQL-only thread resolution" 0
	else
		print_result "dispatch prompt explains GraphQL-only thread resolution" 1 "prompt=$(tr '\n' ' ' <"$HEADLESS_PROMPT_CAPTURE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_launches_targeted_worker_with_human_opt_in() {
	setup_test_env
	export STUB_THREADS_MODE="human"
	PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	wait_for_headless_log || true
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ -s "$HEADLESS_LOG" && -f "$state_file" ]] && grep -q 'Target: PR #1 in owner/repo' "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null; then
		print_result "dispatch-pr launches bounded targeted worker with human opt-in" 0
	else
		print_result "dispatch-pr launches bounded targeted worker with human opt-in" 1 "headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), state=${state_file}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_is_idempotent_for_same_fingerprint() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	: >"$HEADLESS_LOG"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if [[ ! -s "$HEADLESS_LOG" ]]; then
		print_result "dispatch skips same fingerprint during cooldown" 0
	else
		print_result "dispatch skips same fingerprint during cooldown" 1 "second dispatch unexpectedly launched"
	fi
	teardown_test_env
	return 0
}

test_dispatch_skips_mixed_fingerprint_during_inflight_window() {
	setup_test_env
	export STUB_THREADS_MODE="human"
	PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	wait_for_headless_log || true
	: >"$HEADLESS_LOG"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if [[ ! -s "$HEADLESS_LOG" ]]; then
		print_result "dispatch skips mixed fingerprint during in-flight window" 0
	else
		print_result "dispatch skips mixed fingerprint during in-flight window" 1 "mixed fingerprint dispatch unexpectedly launched"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_skips_when_pr_lock_held() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$(date +%s)"
	} >"${lock_dir}/metadata"
	$SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	if [[ ! -s "$HEADLESS_LOG" ]]; then
		print_result "dispatch-pr skips when repo PR lock is held" 0
	else
		print_result "dispatch-pr skips when repo PR lock is held" 1 "lock-held dispatch unexpectedly launched"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_reclaims_stale_lock() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	local old_epoch=""
	old_epoch="$(($(date +%s) - 120))"
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "999999"
		printf 'created_at=%s\n' "$old_epoch"
	} >"${lock_dir}/metadata"
	PR_REVIEW_THREAD_RESPONSE_LOCK_STALE=60 $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	wait_for_headless_log || true
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ -s "$HEADLESS_LOG" && -f "$state_file" && ! -d "$lock_dir" ]]; then
		print_result "dispatch-pr reclaims stale repo PR lock" 0
	else
		print_result "dispatch-pr reclaims stale repo PR lock" 1 "headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), state=${state_file}, lock_dir=${lock_dir}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_reports_graphql_budget_exhaustion_when_scan_blind() {
	setup_test_env
	export STUB_THREADS_MODE="rate_limit"
	export STUB_GRAPHQL_REMAINING="0"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if grep -q 'dispatch: owner/repo skipped — GraphQL budget exhausted (1 PRs uncheckable)' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch reports GraphQL exhaustion instead of no active PRs" 0
	else
		print_result "dispatch reports GraphQL exhaustion instead of no active PRs" 1 "log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_reports_fetch_errors_when_scan_blind() {
	setup_test_env
	export STUB_THREADS_MODE="error"
	export STUB_GRAPHQL_REMAINING="100"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if grep -q 'dispatch: owner/repo skipped — 1 PRs had fetch errors' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch reports fetch errors instead of no active PRs" 0
	else
		print_result "dispatch reports fetch errors instead of no active PRs" 1 "log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_rotates_candidates_with_repo_cursor() {
	setup_test_env
	export PR_REVIEW_THREAD_RESPONSE_MAX_PER_REPO=2
	export STUB_PR_LIST=$'1	One	false	origin:worker	feature/one	worker-bot
2	Two	false	origin:worker	feature/two	worker-bot
3	Three	false	origin:worker	feature/three	worker-bot
4	Four	false	origin:worker	feature/four	worker-bot
5	Five	false	origin:worker	feature/five	worker-bot'
	local state_dir="$AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR"
	local cursor_file="${state_dir}/owner-repo-cursor.state"

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local first_window=""
	first_window="$(for pr_number in 1 2 3 4 5; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	rm -f "${state_dir}"/owner-repo-[0-9]*.state

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local second_window=""
	second_window="$(for pr_number in 1 2 3 4 5; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	rm -f "${state_dir}"/owner-repo-[0-9]*.state

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local third_window=""
	third_window="$(for pr_number in 1 2 3 4 5; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	local cursor_value=""
	cursor_value="$(grep '^pr_number=' "$cursor_file" 2>/dev/null || true)"

	if [[ "$first_window" == "12" && "$second_window" == "34" && "$third_window" == "15" && "$cursor_value" == "pr_number=1" ]]; then
		print_result "dispatch rotates candidate windows with repo cursor" 0
	else
		print_result "dispatch rotates candidate windows with repo cursor" 1 "first=${first_window}, second=${second_window}, third=${third_window}, cursor=${cursor_value}, log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_stale_cursor_falls_back_to_original_order() {
	setup_test_env
	export PR_REVIEW_THREAD_RESPONSE_MAX_PER_REPO=2
	export STUB_PR_LIST=$'1	One	false	origin:worker	feature/one	worker-bot
2	Two	false	origin:worker	feature/two	worker-bot
3	Three	false	origin:worker	feature/three	worker-bot'
	local state_dir="$AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR"
	local cursor_file="${state_dir}/owner-repo-cursor.state"
	printf 'pr_number=999\n' >"$cursor_file"

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local dispatched_window=""
	dispatched_window="$(for pr_number in 1 2 3; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	local cursor_value=""
	cursor_value="$(grep '^pr_number=' "$cursor_file" 2>/dev/null || true)"

	if [[ "$dispatched_window" == "12" && "$cursor_value" == "pr_number=2" ]]; then
		print_result "dispatch stale cursor falls back to original order" 0
	else
		print_result "dispatch stale cursor falls back to original order" 1 "window=${dispatched_window}, cursor=${cursor_value}"
	fi
	teardown_test_env
	return 0
}

test_reply_and_resolve_use_graphql_mutations() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\n@reviewer fixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	$SCANNER resolve owner/repo THREAD1
	if grep -q '^reply$' "$GRAPHQL_MUTATIONS_LOG" 2>/dev/null && grep -q '^resolve$' "$GRAPHQL_MUTATIONS_LOG" 2>/dev/null; then
		print_result "reply and resolve use GraphQL mutations" 0
	else
		print_result "reply and resolve use GraphQL mutations" 1 "mutations=$(tr '\n' ',' <"$GRAPHQL_MUTATIONS_LOG" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_reply_auto_prepends_thread_author() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	local captured=""
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\nfixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	captured=$(<"$GRAPHQL_BODY_CAPTURE")
	if [[ "$captured" == @reviewer\ * ]]; then
		print_result "reply prepends review thread author mention" 0
	else
		print_result "reply prepends review thread author mention" 1 "body=${captured}"
	fi
	teardown_test_env
	return 0
}

test_reply_does_not_double_prepend_thread_author() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	local mention_count=""
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\n@reviewer fixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	mention_count=$(grep -o '@reviewer' "$GRAPHQL_BODY_CAPTURE" 2>/dev/null | wc -l | tr -d '[:space:]')
	if [[ "$mention_count" == "1" ]]; then
		print_result "reply does not double-prepend thread author mention" 0
	else
		print_result "reply does not double-prepend thread author mention" 1 "count=${mention_count}"
	fi
	teardown_test_env
	return 0
}

test_reply_falls_back_when_thread_author_missing() {
	setup_test_env
	export STUB_THREAD_AUTHOR_MODE="missing"
	local body_file="${TEST_ROOT}/reply.md"
	local captured=""
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\nfixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	captured=$(<"$GRAPHQL_BODY_CAPTURE")
	if [[ "$captured" == '<!-- aidevops:review-thread-response:THREAD1 -->'* ]]; then
		print_result "reply falls back when thread author is missing" 0
	else
		print_result "reply falls back when thread author is missing" 1 "body=${captured}"
	fi
	teardown_test_env
	return 0
}

test_reply_skips_duplicate_marker() {
	setup_test_env
	export STUB_THREADS_MODE="marker"
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB_MARKER'
#!/usr/bin/env bash
if [[ "$1" == "api" && "${2:-}" == "rate_limit" ]]; then
	printf '100\n'
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "graphql" ]]; then
	if [[ "$*" == *"comments(first: 100)"* ]]; then
		printf '{"data":{"node":{"comments":{"nodes":[{"body":"<!-- aidevops:review-thread-response:THREAD1 --> already"}]}}}}\n'
		exit 0
	fi
	if [[ "$*" == *"addPullRequestReviewThreadReply"* ]]; then
		printf 'reply\n' >>"${GRAPHQL_MUTATIONS_LOG:-/dev/null}"
		printf '{}\n'
		exit 0
	fi
fi
printf '{}\n'
exit 0
GH_STUB_MARKER
	chmod +x "${TEST_ROOT}/bin/gh"
	local body_file="${TEST_ROOT}/reply.md"
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\n@reviewer duplicate\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	if [[ ! -s "$GRAPHQL_MUTATIONS_LOG" ]]; then
		print_result "reply skips duplicate idempotency marker" 0
	else
		print_result "reply skips duplicate idempotency marker" 1 "unexpected mutation"
	fi
	teardown_test_env
	return 0
}

main() {
	test_scan_finds_unresolved_bot_thread
	test_scan_skips_draft_prs
	test_scan_includes_outdated_unresolved_threads
	test_scan_pr_excludes_human_threads_by_default
	test_scan_pr_can_include_human_threads_with_opt_in
	test_dispatch_launches_worker_and_writes_state
	test_dispatch_prompt_uses_framework_script_path
	test_dispatch_prompt_mentions_graphql_only_thread_operations
	test_dispatch_pr_launches_targeted_worker_with_human_opt_in
	test_dispatch_is_idempotent_for_same_fingerprint
	test_dispatch_skips_mixed_fingerprint_during_inflight_window
	test_dispatch_pr_skips_when_pr_lock_held
	test_dispatch_pr_reclaims_stale_lock
	test_dispatch_reports_graphql_budget_exhaustion_when_scan_blind
	test_dispatch_reports_fetch_errors_when_scan_blind
	test_dispatch_rotates_candidates_with_repo_cursor
	test_dispatch_stale_cursor_falls_back_to_original_order
	test_reply_and_resolve_use_graphql_mutations
	test_reply_auto_prepends_thread_author
	test_reply_does_not_double_prepend_thread_author
	test_reply_falls_back_when_thread_author_missing
	test_reply_skips_duplicate_marker

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
