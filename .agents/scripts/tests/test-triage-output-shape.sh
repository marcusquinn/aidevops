#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2019: Unit tests for the triage-review output-shape and JSON
# extraction path in pulse-ancillary-dispatch.sh.
#
# What this guards:
#   - _extract_review_text_from_json correctly extracts text events
#     from OpenCode --format json output.
#   - _extract_review_text_from_json correctly extracts text events
#     from Claude CLI --output-format stream-json output.
#   - _extract_review_text_from_json falls back to raw content when
#     no JSON events parse (legacy/plain-text path).
#   - The oversized-output ceiling suppresses >20KB extracted text.
#   - The no-review-header path suppresses JSON output whose extracted
#     text has no `## Review:` header (the #18428 failure mode).
#   - A clean review embedded in JSON is accepted and passes through
#     the safety filter.
#   - The debug log is written for every suppression path.
#   - _redact_infra_markers masks sandbox / runtime internals.
#
# Harness style: mocked gh, isolated HOME, stub cache helpers.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
GH_CALL_LOG=""
LOGFILE=""

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
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/agents/scripts"
	LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	: >"$LOGFILE"
	GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_CALL_LOG"
	return 0
}

teardown_test_env() {
	export HOME="${ORIGINAL_HOME}"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Mock gh that records calls. Every call returns success so the
# dispatch path can complete without real network access.
gh() {
	printf '%s\n' "$*" >>"$GH_CALL_LOG"
	case "${1:-}" in
	api)
		# Return empty JSON for any read, zero for count queries.
		printf '0\n'
		return 0
		;;
	esac
	return 0
}
export -f gh

# Stub cache helpers and lock helpers so _dispatch_triage_review_worker
# can be invoked directly without sourcing the full pulse-wrapper boot.
_triage_content_hash() { printf 'deadbeef\n'; }
_triage_is_cached() { return 1; }
_triage_update_cache() { return 0; }
_triage_increment_failure() { return 1; }
_triage_awaiting_contributor_reply() { return 1; }
lock_issue_for_worker() { return 0; }
unlock_issue_after_worker() { return 0; }
export -f _triage_content_hash _triage_is_cached _triage_update_cache \
	_triage_increment_failure _triage_awaiting_contributor_reply \
	lock_issue_for_worker unlock_issue_after_worker

# Load just the functions under test from the production file using
# awk/sed extraction — same pattern as test-triage-failure-escalation.sh.
# We load:
#   - _extract_review_text_from_json
#   - _redact_infra_markers
#   - _log_suppressed_triage_output
#   - _ensure_triage_failed_label
#   - _post_triage_escalation_comment
#   - _dispatch_triage_review_worker
load_helpers_under_test() {
	local src
	local here
	here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	src="${AIDEVOPS_SOURCE:-${here}/../pulse-ancillary-dispatch.sh}"
	if [[ ! -f "$src" ]]; then
		printf 'ERROR: cannot locate pulse-ancillary-dispatch.sh (tried %s)\n' "$src" >&2
		exit 2
	fi
	# Extract from _ensure_triage_failed_label down to (but not
	# including) dispatch_triage_reviews — this includes every helper
	# we need plus _dispatch_triage_review_worker itself.
	local tmp
	tmp=$(mktemp)
	awk '
	/^_ensure_triage_failed_label\(\) \{/{flag=1}
	flag{print}
	/^dispatch_triage_reviews\(\) \{/{flag=0}
	' "$src" |
		sed '/^dispatch_triage_reviews()/,$d' >"$tmp"
	# shellcheck disable=SC1090
	source "$tmp"
	rm -f "$tmp"
	return 0
}

# ------------------------------ Helpers ------------------------------

# Write an OpenCode-format JSON output file containing a review text.
_make_opencode_json() {
	local output_file="$1"
	local text="$2"
	# Escape backslashes and double-quotes for JSON, then encode newlines.
	local escaped
	escaped=$(printf '%s' "$text" | python3 -c '
import json, sys
sys.stdout.write(json.dumps(sys.stdin.read()))
')
	{
		printf '{"type":"step_start","sessionID":"test-session"}\n'
		printf '{"type":"text","text":%s}\n' "$escaped"
		printf '{"type":"step_finish"}\n'
	} >"$output_file"
}

# Write a Claude CLI stream-json output file containing a review text.
_make_claude_stream_json() {
	local output_file="$1"
	local text="$2"
	local escaped
	escaped=$(printf '%s' "$text" | python3 -c '
import json, sys
sys.stdout.write(json.dumps(sys.stdin.read()))
')
	{
		printf '{"type":"system","subtype":"init"}\n'
		printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$escaped"
		printf '{"type":"result","subtype":"success"}\n'
	} >"$output_file"
}

# Make a sandboxed headless-runtime-helper stub that copies a pre-prepared
# file to the output file path the caller passes.
_install_headless_stub() {
	local payload_file="$1"
	local stub_dir="${TEST_ROOT}/stubs"
	mkdir -p "$stub_dir"
	export HEADLESS_RUNTIME_HELPER="${stub_dir}/headless-runtime-helper.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<STUB_EOF
#!/usr/bin/env bash
# Test stub: concatenate the payload to stdout so the caller's
# >"\$review_output_file" 2>&1 captures it.
cat "${payload_file}"
exit 0
STUB_EOF
	chmod +x "$HEADLESS_RUNTIME_HELPER"
	return 0
}

# ------------------------------ Tests ------------------------------

test_extract_opencode_json_returns_text() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "## Review: Approved

### Issue Validation

Looks good."
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Approved"* && "$extracted" == *"Looks good"* ]]; then
		print_result "_extract_review_text_from_json extracts OpenCode text events" 0
	else
		print_result "_extract_review_text_from_json extracts OpenCode text events" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_extract_claude_stream_json_returns_text() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_claude_stream_json "$payload" "## Review: Needs Changes

### Solution Evaluation

Refactor needed."
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Needs Changes"* && "$extracted" == *"Refactor needed"* ]]; then
		print_result "_extract_review_text_from_json extracts Claude stream-json assistant events" 0
	else
		print_result "_extract_review_text_from_json extracts Claude stream-json assistant events" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_extract_plain_text_fallback() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	printf '## Review: Approved\n\nThis is plain text, no JSON.\n' >"$payload"
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Approved"* ]]; then
		print_result "_extract_review_text_from_json falls back to raw content when no JSON" 0
	else
		print_result "_extract_review_text_from_json falls back to raw content when no JSON" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_extract_concats_multiple_text_events() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	{
		printf '{"type":"text","text":"## Review: Approved\\n"}\n'
		printf '{"type":"text","text":"\\n### Issue Validation\\n"}\n'
		printf '{"type":"text","text":"Looks correct."}\n'
	} >"$payload"
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Approved"* && "$extracted" == *"Looks correct"* ]]; then
		print_result "_extract_review_text_from_json concatenates multiple text events" 0
	else
		print_result "_extract_review_text_from_json concatenates multiple text events" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_redact_infra_markers_masks_sandbox_lines() {
	setup_test_env
	load_helpers_under_test
	local sample="Normal line
[SANDBOX] starting worker
[INFO] Executing opencode run --agent build-plus
timeout=300s network_blocked=true
/opt/homebrew/bin/opencode
/Users/alice/Git/secret-repo/file
End of sample"
	local redacted
	redacted=$(_redact_infra_markers "$sample")
	local ok=0
	[[ "$redacted" == *"SANDBOX_REDACTED"* ]] || ok=1
	[[ "$redacted" == *"INFO_REDACTED"* ]] || ok=1
	[[ "$redacted" == *"timeout=REDACTED"* ]] || ok=1
	[[ "$redacted" == *"network_blocked=REDACTED"* ]] || ok=1
	[[ "$redacted" == *"/REDACTED_PATH"* ]] || ok=1
	[[ "$redacted" == *"/REDACTED_USER_PATH"* ]] || ok=1
	# And the infrastructure values themselves must NOT survive
	[[ "$redacted" != *"Users/alice/Git/secret-repo"* ]] || ok=1
	[[ "$redacted" != *"opt/homebrew"* ]] || ok=1
	if [[ $ok -eq 0 ]]; then
		print_result "_redact_infra_markers masks sandbox / runtime internals" 0
	else
		print_result "_redact_infra_markers masks sandbox / runtime internals" 1 \
			"redacted='$redacted'"
	fi
	teardown_test_env
}

test_dispatch_accepts_clean_review_in_json() {
	setup_test_env
	load_helpers_under_test
	# Synthesise the runtime output the stub will return: a clean review
	# wrapped in OpenCode JSON.
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "## Review: Approved

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes | Documented |
| Not duplicate | Yes | none found |
| Actual bug | Yes | confirmed |
| In scope | Yes | project goal |

**Root Cause:** Off-by-one in loop bound.

### Scope & Recommendation

- **Scope creep:** Low
- **Complexity tier:** \`tier:simple\`
- **Decision:** APPROVE
- **Recommended labels:** bug, tier:simple
- **Implementation guidance:** Fix the loop bound at line 42."
	_install_headless_stub "$payload"

	# Ensure the prompt file exists (the dispatcher rm -f's it).
	local prompt_file="${TEST_ROOT}/prompt.txt"
	printf 'test prompt\n' >"$prompt_file"

	_dispatch_triage_review_worker \
		"18400" "owner/repo" "/tmp/repo" "$prompt_file" "hash123" "" \
		2>/dev/null
	if grep -q 'issue comment 18400 --repo owner/repo --body ## Review: Approved' "$GH_CALL_LOG"; then
		print_result "dispatch accepts clean review embedded in OpenCode JSON" 0
	else
		print_result "dispatch accepts clean review embedded in OpenCode JSON" 1 \
			"gh call log (last lines):
$(tail -5 "$GH_CALL_LOG")"
	fi
	teardown_test_env
}

test_dispatch_suppresses_oversized_output() {
	setup_test_env
	load_helpers_under_test
	# Build a 25KB review that DOES have a ## Review header. The size
	# ceiling should catch it BEFORE the header check, tagging as
	# oversized-output.
	local long_body
	long_body="## Review: Needs Changes

$(python3 -c 'print("x" * 24000)')

More content..."
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$long_body"
	_install_headless_stub "$payload"

	local prompt_file="${TEST_ROOT}/prompt.txt"
	printf 'test prompt\n' >"$prompt_file"

	_dispatch_triage_review_worker \
		"18401" "owner/repo" "/tmp/repo" "$prompt_file" "hash124" "" \
		2>/dev/null

	# Must NOT have posted a review comment
	if grep -q 'issue comment 18401 --repo owner/repo --body' "$GH_CALL_LOG"; then
		print_result "dispatch suppresses oversized output (>20KB)" 1 \
			"gh issue comment was called despite oversized output"
		teardown_test_env
		return 0
	fi
	# Must have logged the oversized suppression
	if grep -q 'oversized output' "$LOGFILE"; then
		print_result "dispatch suppresses oversized output (>20KB)" 0
	else
		print_result "dispatch suppresses oversized output (>20KB)" 1 \
			"LOGFILE did not contain 'oversized output'
LOGFILE: $(cat "$LOGFILE")"
	fi
	# Debug log must exist and contain the failure_reason tag.
	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if [[ -f "$debug_log" ]] && grep -q 'failure_reason: oversized-output' "$debug_log"; then
		print_result "oversized suppression writes to debug log with correct tag" 0
	else
		print_result "oversized suppression writes to debug log with correct tag" 1 \
			"debug log missing or wrong content"
	fi
	teardown_test_env
}

test_dispatch_suppresses_headerless_json_output() {
	setup_test_env
	load_helpers_under_test
	# JSON output that does NOT contain `## Review:` anywhere in the text.
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "I'll analyze this issue. Looking at the context, it seems reasonable. I recommend approving but I don't have a ## Review header here because the model drifted."
	_install_headless_stub "$payload"

	local prompt_file="${TEST_ROOT}/prompt.txt"
	printf 'test prompt\n' >"$prompt_file"

	_dispatch_triage_review_worker \
		"18402" "owner/repo" "/tmp/repo" "$prompt_file" "hash125" "" \
		2>/dev/null

	# Must NOT have posted a review comment
	if grep -q 'issue comment 18402 --repo owner/repo --body' "$GH_CALL_LOG"; then
		print_result "dispatch suppresses headerless JSON output" 1 \
			"gh issue comment was called despite missing ## Review header"
		teardown_test_env
		return 0
	fi
	# Debug log should have no-review-header tag
	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if [[ -f "$debug_log" ]] && grep -q 'failure_reason: no-review-header' "$debug_log"; then
		print_result "dispatch suppresses headerless JSON output with no-review-header tag" 0
	else
		print_result "dispatch suppresses headerless JSON output with no-review-header tag" 1 \
			"debug log content:
$(cat "$debug_log" 2>/dev/null || echo "<missing>")"
	fi
	teardown_test_env
}

test_dispatch_suppresses_raw_sandbox_output() {
	setup_test_env
	load_helpers_under_test
	# Raw (non-JSON) output containing infra markers — simulates the
	# attempt-3 failure mode on #18428.
	local payload="${TEST_ROOT}/payload.json"
	cat >"$payload" <<'RAW_EOF'
[SANDBOX] starting worker with timeout=300s network_blocked=true
[INFO] Executing opencode run --agent build-plus
/opt/homebrew/bin/opencode: loading config
Model response: error reading file
RAW_EOF
	_install_headless_stub "$payload"

	local prompt_file="${TEST_ROOT}/prompt.txt"
	printf 'test prompt\n' >"$prompt_file"

	_dispatch_triage_review_worker \
		"18403" "owner/repo" "/tmp/repo" "$prompt_file" "hash126" "" \
		2>/dev/null

	# Must NOT have posted a review comment
	if grep -q 'issue comment 18403 --repo owner/repo --body' "$GH_CALL_LOG"; then
		print_result "dispatch suppresses raw sandbox output" 1 \
			"gh issue comment was called despite raw sandbox markers"
		teardown_test_env
		return 0
	fi
	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if [[ -f "$debug_log" ]] && grep -q 'failure_reason: raw-sandbox-output' "$debug_log"; then
		print_result "dispatch suppresses raw sandbox output with raw-sandbox-output tag" 0
	else
		print_result "dispatch suppresses raw sandbox output with raw-sandbox-output tag" 1 \
			"debug log content:
$(cat "$debug_log" 2>/dev/null || echo "<missing>")"
	fi
	# Debug log sample must be REDACTED, not contain the literal path.
	if [[ -f "$debug_log" ]] && ! grep -q '/opt/homebrew' "$debug_log"; then
		print_result "debug log sample has infrastructure paths redacted" 0
	else
		print_result "debug log sample has infrastructure paths redacted" 1 \
			"debug log still contains /opt/homebrew"
	fi
	teardown_test_env
}

test_post_escalation_handles_oversized_reason() {
	setup_test_env
	load_helpers_under_test
	# MOCK_COMMENTS_MARKER_COUNT was used in the t2016 test; we
	# redefine gh here to always return 0 (no existing marker) so the
	# escalation helper posts a comment.
	gh() {
		printf '%s\n' "$*" >>"$GH_CALL_LOG"
		case "${1:-}" in
		api)
			printf '0\n'
			return 0
			;;
		esac
		return 0
	}
	export -f gh
	_post_triage_escalation_comment "18404" "owner/repo" "oversized-output" 1 25000
	if grep -q '^issue comment 18404 --repo owner/repo --body-file' "$GH_CALL_LOG"; then
		print_result "_post_triage_escalation_comment accepts oversized-output reason and posts" 0
	else
		print_result "_post_triage_escalation_comment accepts oversized-output reason and posts" 1 \
			"gh call log did not contain issue comment invocation"
	fi
	teardown_test_env
}

main() {
	test_extract_opencode_json_returns_text
	test_extract_claude_stream_json_returns_text
	test_extract_plain_text_fallback
	test_extract_concats_multiple_text_events
	test_redact_infra_markers_masks_sandbox_lines
	test_dispatch_accepts_clean_review_in_json
	test_dispatch_suppresses_oversized_output
	test_dispatch_suppresses_headerless_json_output
	test_dispatch_suppresses_raw_sandbox_output
	test_post_escalation_handles_oversized_reason

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
