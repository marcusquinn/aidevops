#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23605: GitHub secondary-rate-limit responses create a
# shared cooldown state and subsequent noncritical gh calls skip without
# invoking gh until the cooldown expires or an explicit override is present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
CALL_LOG="${TMP_HOME}/gh-calls.log"
ERR_LOG="${TMP_HOME}/stderr.log"
: >"$CALL_LOG"
: >"$ERR_LOG"

cleanup() {
	rm -rf "$TMP_HOME"
	return 0
}
trap cleanup EXIT

export HOME="$TMP_HOME"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${TMP_HOME}/.aidevops/cache/gh-secondary-cooldown.json"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS=600

gh() {
	printf 'GH %s\n' "$*" >>"$CALL_LOG"
	if [[ "${GH_SECONDARY_FAIL:-0}" == "1" ]]; then
		printf '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}\n' >&2
		return 1
	fi
	if [[ "${GH_HEADER_LIMIT_FAIL:-0}" == "1" ]]; then
		printf 'HTTP/2 429\r\nRetry-After: 42\r\nX-RateLimit-Remaining: 0\r\nX-GitHub-Request-Id: REQ-429\r\n\r\n{"message":"rate limit exceeded"}\n'
		return 1
	fi
	printf '{"ok":true}\n'
	return 0
}

# shellcheck source=../shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

reset_case() {
	: >"$CALL_LOG"
	: >"$ERR_LOG"
	rm -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
	unset GH_SECONDARY_FAIL GH_HEADER_LIMIT_FAIL AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE 2>/dev/null || true
	_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=0
	return 0
}

test_secondary_response_writes_cooldown() {
	reset_case
	export GH_SECONDARY_FAIL=1
	set +e
	_gh_with_timeout read gh api repos/owner/repo/issues >"${TMP_HOME}/out.json" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && \
		jq -e '.reason == "github-secondary-rate-limit" and (.expires_at > .first_seen)' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS secondary response writes cooldown file\n'
		return 0
	fi
	printf 'FAIL cooldown file missing or malformed\n'
	return 1
}

test_header_response_writes_retry_after_cooldown() {
	reset_case
	export GH_HEADER_LIMIT_FAIL=1
	set +e
	_gh_with_timeout read gh api -i repos/owner/repo/issues >"${TMP_HOME}/headers.out" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected header-limited wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && \
		jq -e '.reason == "github-api-rate-limit-status-429" and .last_request_id == "REQ-429" and ((.expires_at - .first_seen) >= 40) and ((.expires_at - .first_seen) <= 45)' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS header response writes retry-after cooldown file\n'
		return 0
	fi
	printf 'FAIL header cooldown file missing or malformed\n'
	return 1
}

test_active_cooldown_skips_without_gh_call() {
	reset_case
	_gh_secondary_cooldown_write "test-secondary" "fixture" >/dev/null 2>&1
	set +e
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/skip.json" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -eq 75 ]] && [[ ! -s "$CALL_LOG" ]] && grep -q 'secondary-rate-limit active=true skip=read' "$ERR_LOG"; then
		printf 'PASS active cooldown skips noncritical gh call\n'
		return 0
	fi
	printf 'FAIL active cooldown did not skip as expected\n'
	sed 's/^/  /' "$CALL_LOG"
	sed 's/^/  /' "$ERR_LOG"
	return 1
}

test_override_allows_audited_call() {
	reset_case
	_gh_secondary_cooldown_write "test-secondary" "fixture" >/dev/null 2>&1
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE=1
	_gh_with_timeout write gh issue comment 123 --repo owner/repo --body ok >"${TMP_HOME}/override.json" 2>"$ERR_LOG"
	if grep -q 'GH issue comment 123' "$CALL_LOG" && grep -q 'secondary-rate-limit override=true op=write' "$ERR_LOG"; then
		printf 'PASS explicit override allows audited critical call\n'
		return 0
	fi
	printf 'FAIL override did not invoke gh with audit log\n'
	return 1
}

test_default_path_without_home_is_user_scoped() {
	local default_path=""
	# shellcheck disable=SC2016 # $1 is expanded by the nested bash process.
	default_path=$(env -u HOME -u AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME -u AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE USER=tester bash -c 'source "$1"; _gh_secondary_cooldown_file' bash "${SCRIPT_DIR}/shared-gh-secondary-cooldown.sh")
	if [[ "$default_path" == "/tmp/.aidevops-tester/.aidevops/cache/gh-secondary-cooldown.json" ]]; then
		printf 'PASS default cooldown path without HOME is user scoped\n'
		return 0
	fi
	printf 'FAIL default cooldown path without HOME was not user scoped: %s\n' "$default_path"
	return 1
}

test_no_jq_fallback_escapes_json_strings() {
	reset_case
	local nojq_bin="${TMP_HOME}/nojq-bin"
	local tool=""
	mkdir -p "$nojq_bin"
	for tool in date mkdir mv sed; do
		ln -sf "$(command -v "$tool")" "${nojq_bin}/${tool}"
	done
	PATH="$nojq_bin" _gh_secondary_cooldown_write 'quote " reason' 'request id: REQ-123' >/dev/null 2>&1
	if jq -e '.reason == "quote \" reason" and .last_request_id == "REQ-123" and (.expires_at > .first_seen)' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS no-jq fallback escapes JSON strings\n'
		return 0
	fi
	printf 'FAIL no-jq fallback wrote malformed JSON\n'
	return 1
}

test_header_parsers_ignore_response_body() {
	local response_text=$'HTTP/2 200\r\nX-RateLimit-Remaining: 5\r\n\r\nX-RateLimit-Remaining: 0\nHTTP/2 429'
	local remaining=""
	local status=""

	remaining="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-remaining")"
	status="$(_gh_secondary_cooldown_status "$response_text")"
	if [[ "$remaining" == "5" && "$status" == "200" ]]; then
		printf 'PASS header parsers ignore response body lookalikes\n'
		return 0
	fi
	printf 'FAIL header parsers read body lookalikes: status=%s remaining=%s\n' "$status" "$remaining"
	return 1
}

test_timeout_temp_cleanup_when_out_mktemp_fails() {
	reset_case
	local leaked_file="${TMP_HOME}/leaked.err"
	_GH_TEST_MKTEMP_CALLS=0
	mktemp() {
		local template="${1:-}"
		: "$template"
		_GH_TEST_MKTEMP_CALLS=$((_GH_TEST_MKTEMP_CALLS + 1))
		if [[ "$_GH_TEST_MKTEMP_CALLS" -eq 1 ]]; then
			: >"$leaked_file"
			printf '%s\n' "$leaked_file"
			return 0
		fi
		return 1
	}
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/mktemp-fail.out" 2>"$ERR_LOG"
	local rc=$?
	unset -f mktemp
	unset _GH_TEST_MKTEMP_CALLS
	if [[ "$rc" -eq 0 && ! -e "$leaked_file" ]] && grep -q 'GH issue list --repo owner/repo' "$CALL_LOG"; then
		printf 'PASS timeout wrapper cleans partial temp file on mktemp failure\n'
		return 0
	fi
	printf 'FAIL timeout wrapper leaked partial temp file or skipped command\n'
	return 1
}

test_secondary_response_writes_cooldown
test_header_response_writes_retry_after_cooldown
test_active_cooldown_skips_without_gh_call
test_override_allows_audited_call
test_default_path_without_home_is_user_scoped
test_no_jq_fallback_escapes_json_strings
test_header_parsers_ignore_response_body
test_timeout_temp_cleanup_when_out_mktemp_fails
