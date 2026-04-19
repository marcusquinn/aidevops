#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-model-availability-oauth-token.sh — t2392 regression guard.
#
# Asserts that the OpenCode OAuth auth path no longer misroutes OAuth
# access tokens as Anthropic static API keys. Three assertions:
#
#   1. resolve_api_key for a provider whose auth.json entry has
#      `type == "oauth"` and a FUTURE `expires` returns the synthetic
#      marker `oauth-refresh-available` — NOT the raw OAuth access
#      token. Pre-t2392 behaviour returned the raw token, which caused
#      HTTP 401 bad-key against /v1/models and starved opus/sonnet
#      tier dispatch in the pulse.
#
#   2. resolve_api_key for an OAuth entry with PAST `expires` still
#      returns `oauth-refresh-available` (pre-existing t1927 behaviour
#      must be preserved across the t2392 refactor).
#
#   3. _probe_resolve_and_validate_key, when given an OAuth-prefix
#      access token (`sk-ant-oat01-...`) via ANTHROPIC_API_KEY env
#      var, returns exit code 100 (healthy-skip) — the defensive
#      belt-and-braces for users who export auth.json tokens directly
#      into env vars.
#
# Failure history motivating this test: 2026-04-19 pulse dispatch
# drought — 34 open issues, 16+ clearly dispatchable, but
# `issues_dispatched: 0`. Root cause: `resolve_api_key` returned
# `sk-ant-oat01-...` when auth.json had `type == "oauth"` and the
# access token was not yet expired. `_probe_build_request` sent it as
# `x-api-key`, Anthropic rejected it (OAuth requires Authorization:
# Bearer), provider marked unhealthy, `resolve_tier opus` failed,
# deterministic-fill-floor enumerated candidates but dispatched zero.

# NOTE: not using `set -e` — assertion 3 captures a non-zero exit
# (return 100 from _probe_resolve_and_validate_key) and must not kill
# the test runner.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# NOT readonly — shared-constants.sh (transitively sourced) declares
# `readonly RED/GREEN/RESET` and a collision under set -e would silently
# kill the test shell.
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME so sourcing cannot touch real auth.json / availability DB.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.local/share/opencode" "${HOME}/.aidevops/.agent-workspace/availability"

AUTH_FILE="${HOME}/.local/share/opencode/auth.json"

# Unset env vars that might leak real credentials into the test.
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true

# Source the helper. It prints a help banner on no-args — redirect stdout
# so the test output stays clean. The `main "$@"` at EOF defaults to help.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/model-availability-helper.sh" >/dev/null 2>&1

# Sourced `set -euo pipefail` is live — turn -e off so negative tests
# don't silently kill us. -u + -o pipefail stay on.
set +e

# =============================================================================
# Assertion 1 — OAuth-typed entry with FUTURE expires
# =============================================================================
# Pre-t2392: returned raw $access_token (bug). Post-t2392: returns
# oauth-refresh-available regardless of expiry.

future_ms=$(($(date +%s) * 1000 + 3600000)) # 1h in future
cat >"$AUTH_FILE" <<JSON
{
  "anthropic": {
    "type": "oauth",
    "access": "sk-ant-oat01-FAKE-FUTURE-TOKEN",
    "refresh": "fake-refresh-future",
    "expires": ${future_ms}
  }
}
JSON

result=$(resolve_api_key anthropic 2>/dev/null)
rc=$?
if [[ "$rc" -eq 0 && "$result" == "oauth-refresh-available" ]]; then
	print_result "oauth+future: resolve_api_key returns oauth-refresh-available" 0
else
	print_result "oauth+future: resolve_api_key returns oauth-refresh-available" 1 \
		"(got rc=$rc, result='$result' — expected rc=0, result='oauth-refresh-available')"
fi

# =============================================================================
# Assertion 2 — OAuth-typed entry with PAST expires (t1927 regression guard)
# =============================================================================
# Pre-existing behaviour: expired OAuth with a refresh token returned
# oauth-refresh-available. t2392 must preserve this — the refactor must
# not regress expired-token handling.

past_ms=$(($(date +%s) * 1000 - 3600000)) # 1h in past
cat >"$AUTH_FILE" <<JSON
{
  "anthropic": {
    "type": "oauth",
    "access": "sk-ant-oat01-FAKE-EXPIRED-TOKEN",
    "refresh": "fake-refresh-past",
    "expires": ${past_ms}
  }
}
JSON

result=$(resolve_api_key anthropic 2>/dev/null)
rc=$?
if [[ "$rc" -eq 0 && "$result" == "oauth-refresh-available" ]]; then
	print_result "oauth+expired: resolve_api_key returns oauth-refresh-available (t1927 preserved)" 0
else
	print_result "oauth+expired: resolve_api_key returns oauth-refresh-available (t1927 preserved)" 1 \
		"(got rc=$rc, result='$result' — expected rc=0, result='oauth-refresh-available')"
fi

# =============================================================================
# Assertion 3 — ANTHROPIC_API_KEY env var with OAuth-prefix token
# =============================================================================
# Defensive: user may have exported their auth.json access token directly
# as ANTHROPIC_API_KEY. _probe_resolve_and_validate_key must detect the
# `sk-ant-oat01-` prefix and return 100 (healthy-skip), not proceed to the
# HTTP probe which would 401.

# Remove the auth.json fixture to force the env-var source path.
rm -f "$AUTH_FILE"
export ANTHROPIC_API_KEY="sk-ant-oat01-FAKE-ENV-TOKEN"

# _probe_resolve_and_validate_key writes to the availability DB via
# _record_health. init_db must succeed first — call it explicitly (main()
# skipped init when sourced with no args / help default).
init_db >/dev/null 2>&1 || {
	print_result "assertion 3 precondition: init_db" 1 "(init_db failed)"
	# Keep going so the summary still reports useful state.
}

# Call the validator with quiet=true to suppress the print_success line.
# Discard stdout (it echoes the api_key on success, which we don't want
# printed even masked). Capture only the exit code.
_probe_resolve_and_validate_key anthropic true >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 100 ]]; then
	print_result "env+oauth-prefix: _probe_resolve_and_validate_key returns 100 (healthy-skip)" 0
else
	print_result "env+oauth-prefix: _probe_resolve_and_validate_key returns 100 (healthy-skip)" 1 \
		"(got rc=$rc — expected 100; bug: probe would attempt x-api-key with OAuth token and 401)"
fi

unset ANTHROPIC_API_KEY

# =============================================================================
# Summary
# =============================================================================
printf '\n%d test(s) run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
