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
	printf '{"ok":true}\n'
	return 0
}

# shellcheck source=../shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

reset_case() {
	: >"$CALL_LOG"
	: >"$ERR_LOG"
	rm -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
	unset GH_SECONDARY_FAIL AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE 2>/dev/null || true
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

test_secondary_response_writes_cooldown
test_active_cooldown_skips_without_gh_call
test_override_allows_audited_call
