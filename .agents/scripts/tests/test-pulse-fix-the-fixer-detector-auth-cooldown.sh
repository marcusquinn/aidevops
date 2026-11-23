#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23430: deterministic AI research auth failures should
# trip a local cooldown so pulse does not call the LLM classifier every cycle.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

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

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache" "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export ANTHROPIC_API_KEY="test-invalid-key"
	export AIDEVOPS_FIX_THE_FIXER_DETECTOR_AUTH_COOLDOWN_SECONDS=3600
	export AIDEVOPS_AI_RESEARCH_PROVIDER=anthropic
	export CURL_COUNT_FILE="${TEST_ROOT}/curl-count"
	printf '0\n' >"$CURL_COUNT_FILE"

	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" && "${2:-}" == repos/*/labels/fix-the-fixer ]]; then
	printf '{"name":"fix-the-fixer"}\n'
	exit 0
fi
body="Touches pulse-wrapper.sh dispatch behaviour."
[[ -f "${ISSUE_BODY_FILE:-}" ]] && body=$(cat "$ISSUE_BODY_FILE")
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	jq -cn --arg body "$body" '[1, 2 | {number: ., title: "fix dispatch path", body: $body, labels: [{name: "auto-dispatch"}]}]'
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	jq -cn --arg body "$body" '{title: "fix dispatch path", body: $body, labels: [{name: "auto-dispatch"}], state: "OPEN"}'
	exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
STUB
	chmod +x "${TEST_ROOT}/bin/gh"

	cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count="0"
if [[ -f "${CURL_COUNT_FILE}" ]]; then
	count=$(tr -cd '0-9' <"${CURL_COUNT_FILE}")
fi
count=$((count + 1))
printf '%s\n' "$count" >"${CURL_COUNT_FILE}"
printf '{"error":{"message":"invalid x-api-key"}}\n'
exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/curl"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_detector() {
	local output_file="$1"
	"${PWD}/.agents/scripts/pulse-fix-the-fixer-detector.sh" run \
		--repo example/repo --limit 2 >"$output_file" 2>&1
	return 0
}

llm_calls() {
	tr -cd '0-9' <"$CURL_COUNT_FILE"
	return 0
}

# GH#38673: verdict cache, rationale propagation, run budget and repo cursor.
assert_cache_budget_cursor() {
	local log="${TEST_ROOT}/cache.log"
	local status_file="${HOME}/.aidevops/cache/fix-the-fixer-detector-status.json"
	cat >"$PULSE_AI_RESEARCH_HELPER_OVERRIDE" <<'STUB'
#!/usr/bin/env bash
count=$(tr -cd '0-9' <"$CURL_COUNT_FILE")
printf '%s\n' "$((count + 1))" >"$CURL_COUNT_FILE"
case "${STUB_MODE:-no}" in
	fail) printf 'upstream overloaded\n' >&2; exit 1 ;;
	slow) sleep 3 ;;
esac
printf 'NO counted rationale\n'
STUB
	export ISSUE_BODY_FILE="${TEST_ROOT}/issue-body"

	# Both issues were classified NO by the preceding recovery run.
	printf '0\n' >"$CURL_COUNT_FILE"
	run_detector "$log"
	if [[ "$(llm_calls)" == "0" ]] && jq -e '.cached == 2 and .processed == 0' "$status_file" >/dev/null; then
		print_result "unchanged issues reuse cached verdicts without LLM calls" 0
	else
		print_result "unchanged issues reuse cached verdicts without LLM calls" 1 "calls=$(llm_calls); log: $(tr '\n' ' ' <"$log")"
	fi

	printf 'Edited body that now names dispatch-dedup-helper.sh.\n' >"$ISSUE_BODY_FILE"
	run_detector "$log"
	if [[ "$(llm_calls)" == "2" ]] && grep -q 'verdict=NO counted rationale' "$log"; then
		print_result "edited content is reclassified and its rationale is logged" 0
	else
		print_result "edited content is reclassified and its rationale is logged" 1 "calls=$(llm_calls); log: $(tr '\n' ' ' <"$log")"
	fi

	printf 'Third body revision.\n' >"$ISSUE_BODY_FILE"
	printf '0\n' >"$CURL_COUNT_FILE"
	STUB_MODE=fail run_detector "$log"
	STUB_MODE=fail run_detector "$log"
	if [[ "$(llm_calls)" == "4" ]] && grep -q 'classification skipped — LLM call failed' "$log"; then
		print_result "LLM failures are not cached and keep their rationale" 0
	else
		print_result "LLM failures are not cached and keep their rationale" 1 "calls=$(llm_calls); log: $(tr '\n' ' ' <"$log")"
	fi

	# Integer SECONDS can tick within milliseconds, so a 2s budget (not 1s)
	# guarantees the first classification starts and the second does not.
	local rc=0
	AIDEVOPS_FIX_THE_FIXER_DETECTOR_BUDGET_SECONDS=2 STUB_MODE=slow run_detector "$log" || rc=$?
	if [[ "$rc" -eq 0 ]] && jq -e '.processed == 1 and .budget_exhausted == true' "$status_file" >/dev/null; then
		print_result "spent budget stops new work and still writes the summary" 0
	else
		print_result "spent budget stops new work and still writes the summary" 1 "rc=${rc}; status: $(tr '\n' ' ' <"$status_file")"
	fi

	# Two dispatch-system repositories plus one product repository, one
	# classification per run: the second run must resume inside the first
	# repository, then hand off to the second; the product repo never counts.
	local repo_name=""
	for repo_name in one two; do
		mkdir -p "${TEST_ROOT}/repos/${repo_name}/.agents/scripts"
		: >"${TEST_ROOT}/repos/${repo_name}/.agents/scripts/pulse-wrapper.sh"
	done
	mkdir -p "${TEST_ROOT}/repos/product" "${HOME}/.config/aidevops"
	jq -n --arg root "${TEST_ROOT}/repos" '{initialized_repos: [
		{slug: "c/product", pulse: true, path: ($root + "/product")},
		{slug: "a/one", pulse: true, path: ($root + "/one")},
		{slug: "b/two", pulse: true, path: ($root + "/two")}]}' \
		>"${HOME}/.config/aidevops/repos.json"
	local cursor_file="${HOME}/.aidevops/cache/fix-the-fixer-detector-cursor"
	"${PWD}/.agents/scripts/pulse-fix-the-fixer-detector.sh" run --limit 1 >"$log" 2>&1
	local first_cursor=""
	first_cursor=$(cat "$cursor_file" 2>/dev/null) || first_cursor=""
	"${PWD}/.agents/scripts/pulse-fix-the-fixer-detector.sh" run --limit 1 >"$log" 2>&1
	local second_cursor=""
	second_cursor=$(cat "$cursor_file" 2>/dev/null) || second_cursor=""
	if [[ "$first_cursor" == "a/one" && "$second_cursor" == "b/two" ]] &&
		jq -e '.repo_count == 2 and .cached == 1 and .processed == 1 and .stop_reason == "limit"' "$status_file" >/dev/null; then
		print_result "repo cursor resumes where the previous run stopped" 0
	else
		print_result "repo cursor resumes where the previous run stopped" 1 "cursors=${first_cursor},${second_cursor}; status: $(tr '\n' ' ' <"$status_file")"
	fi
	# Product repositories without the dispatch system are never scanned.
	"${PWD}/.agents/scripts/pulse-fix-the-fixer-detector.sh" run --limit 10 >"$log" 2>&1
	if jq -e '.repo_count == 2' "$status_file" >/dev/null && ! grep -q 'c/product' "$log"; then
		print_result "repositories without the dispatch system are excluded" 0
	else
		print_result "repositories without the dispatch system are excluded" 1 "status: $(tr '\n' ' ' <"$status_file")"
	fi
	return 0
}

assert_file_mtime_helpers() {
	# shellcheck source=/dev/null
	source "${PWD}/.agents/scripts/pulse-fix-the-fixer-detector.sh"

	if declare -f _file_mtime_epoch >/dev/null 2>&1; then
		print_result "detector imports portable mtime helper" 0
	else
		print_result "detector imports portable mtime helper" 1 "_file_mtime_epoch unavailable"
	fi

	local missing_stamp
	missing_stamp=$(_file_mtime "${TEST_ROOT}/missing-config")
	if [[ "$missing_stamp" == "missing" ]]; then
		print_result "missing config stamp is explicit" 0
	else
		print_result "missing config stamp is explicit" 1 "stamp=${missing_stamp}"
	fi

	_file_mtime_epoch() {
		return 42
	}

	local existing_file="${TEST_ROOT}/existing-config"
	: >"$existing_file"
	local failed_stamp=""
	local rc=0
	failed_stamp=$(_file_mtime "$existing_file") || rc=$?
	if [[ "$rc" -eq 42 && "$failed_stamp" == "unknown" ]]; then
		print_result "mtime helper failures propagate" 0
	else
		print_result "mtime helper failures propagate" 1 "rc=${rc} stamp=${failed_stamp}"
	fi
	return 0
}

main() {
	setup_sandbox
	trap teardown_sandbox EXIT
	assert_file_mtime_helpers

	local first_log="${TEST_ROOT}/first.log"
	local second_log="${TEST_ROOT}/second.log"
	run_detector "$first_log"
	run_detector "$second_log"

	local curl_count
	curl_count=$(tr -cd '0-9' <"$CURL_COUNT_FILE")
	if [[ "$curl_count" == "1" ]]; then
		print_result "invalid credentials trigger cooldown after one LLM call" 0
	else
		print_result "invalid credentials trigger cooldown after one LLM call" 1 "curl calls=${curl_count}"
	fi

	if [[ -f "${HOME}/.aidevops/cache/fix-the-fixer-detector-auth.cooldown" ]]; then
		print_result "auth cooldown state file recorded" 0
	else
		print_result "auth cooldown state file recorded" 1 "cooldown file missing"
	fi

	local first_warn_count
	first_warn_count=$(grep -c 'fix-the-fixer-detector] WARN:' "$first_log" || true)
	if [[ "$first_warn_count" == "1" ]] && ! grep -q 'classification skipped' "$first_log"; then
		print_result "auth failures emit one cycle-level warning" 0
	else
		print_result "auth failures emit one cycle-level warning" 1 "warns=${first_warn_count}; first log: $(tr '\n' ' ' <"$first_log")"
	fi

	local second_warn_count
	second_warn_count=$(grep -c 'fix-the-fixer-detector] WARN:' "$second_log" || true)
	if [[ "$second_warn_count" == "1" ]] && ! grep -q 'classification skipped' "$second_log"; then
		print_result "cooldown skips emit one cycle-level warning" 0
	else
		print_result "cooldown skips emit one cycle-level warning" 1 "warns=${second_warn_count}; second log: $(tr '\n' ' ' <"$second_log")"
	fi

	if grep -q 'skipped:auth-error=2' "$second_log" && grep -q 'AI research credentials invalid' "$second_log"; then
		print_result "subsequent run reports concise auth skip" 0
	else
		print_result "subsequent run reports concise auth skip" 1 "second log: $(tr '\n' ' ' <"$second_log")"
	fi

	# GH#38620: reproduce the actual pure-runtime error without provider access.
	unset ANTHROPIC_API_KEY
	export PULSE_AI_RESEARCH_HELPER_OVERRIDE="${TEST_ROOT}/runtime-research"
	cat >"$PULSE_AI_RESEARCH_HELPER_OVERRIDE" <<'STUB'
#!/usr/bin/env bash
count=$(tr -cd '0-9' <"$CURL_COUNT_FILE")
printf '%s\n' "$((count + 1))" >"$CURL_COUNT_FILE"
printf '%s\n' 'Error: The isolated OpenCode runtime cannot authenticate the Anthropic OAuth provider for the simple tier. Pure public triage does not load the provider-auth plugin; select a provider with native authentication.' >&2
exit 1
STUB
	chmod +x "$PULSE_AI_RESEARCH_HELPER_OVERRIDE"
	printf '0\n' >"$CURL_COUNT_FILE"
	run_detector "$first_log"
	run_detector "$second_log"
	if [[ "$(tr -cd '0-9' <"$CURL_COUNT_FILE")" == "1" ]] &&
		grep -q 'runtime_auth_unavailable' "$second_log" &&
		grep -q 'DEGRADED capability' "$second_log" &&
		grep -q 'aidevops secret set ANTHROPIC_API_KEY' "$second_log" &&
		! grep -q 'credentials invalid' "$second_log"; then
		print_result "runtime failure remains distinct and actionable during cooldown" 0
	else
		print_result "runtime failure remains distinct and actionable during cooldown" 1
	fi
	local status_file="${HOME}/.aidevops/cache/fix-the-fixer-detector-status.json"
	if jq -e '.processed == 2 and .classified == 0 and .skipped_auth == 2' "$status_file" >/dev/null; then
		print_result "fully skipped run persists aggregate degradation evidence" 0
	else
		print_result "fully skipped run persists aggregate degradation evidence" 1
	fi
	# Credential config changes invalidate the cooldown; a valid NO must clear
	# the status without any GitHub writes (the stub rejects all writes).
	export ANTHROPIC_API_KEY="test-recovery-value"
	cat >"$PULSE_AI_RESEARCH_HELPER_OVERRIDE" <<'STUB'
#!/usr/bin/env bash
printf 'NO unrelated change\n'
STUB
	run_detector "$first_log"
	if jq -e '.classified == 2 and .skipped_auth == 0' "$status_file" >/dev/null &&
		[[ ! -f "${HOME}/.aidevops/cache/fix-the-fixer-detector-auth.cooldown" ]]; then
		print_result "configuration recovery clears cooldown and degraded status" 0
	else
		print_result "configuration recovery clears cooldown and degraded status" 1
	fi
	assert_cache_budget_cursor

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
