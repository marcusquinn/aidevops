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
# Assertion 4 — rejected OPENAI_API_KEY + OpenAI OAuth in auth.json (t3555)
# =============================================================================
# The failure mode: OPENAI_API_KEY=invalid is set and auth.json has a valid
# OpenAI OAuth entry. OpenCode's built-in openai provider still routes the run
# through @ai-sdk/openai using the env key, so _probe_check_oauth_fallback must
# NOT report provider health just because OAuth exists.
#
# We cannot invoke probe_provider directly (it makes HTTP calls), but we CAN
# test _probe_check_oauth_fallback in isolation — it reads auth.json and calls
# _record_health. This is the testable unit for the t3555 fix.

export OPENAI_API_KEY="sk-invalid-stale-key-from-old-account"

cat >"$AUTH_FILE" <<JSON
{
  "openai": {
    "type": "oauth",
    "access": "fake-openai-access-token",
    "refresh": "fake-openai-refresh-token"
  }
}
JSON

# init_db may already be done from assertion 3 — reinit is idempotent.
init_db >/dev/null 2>&1 || {
	print_result "assertion 4 precondition: init_db" 1 "(init_db failed)"
}

# _probe_check_oauth_fallback must reject the fallback while OPENAI_API_KEY is
# present because the selected runtime path would reuse the rejected env key.
_probe_check_oauth_fallback openai true "env:OPENAI_API_KEY"
rc=$?
if [[ "$rc" -eq 3 ]]; then
	print_result "rejected-env-key+openai-oauth: _probe_check_oauth_fallback returns 3 (t3555)" 0
else
	print_result "rejected-env-key+openai-oauth: _probe_check_oauth_fallback returns 3 (t3555)" 1 \
		"(got rc=$rc — expected 3; built-in openai would reuse the rejected env key)"
fi

# Assertion 4b — OAuth still wins when the rejected helper key is not from env.
unset OPENAI_API_KEY
_probe_check_oauth_fallback openai true "gopass:OPENAI_API_KEY"
rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "rejected-non-env-key+openai-oauth: _probe_check_oauth_fallback returns 0 (t3229 preserved)" 0
else
	print_result "rejected-non-env-key+openai-oauth: _probe_check_oauth_fallback returns 0 (t3229 preserved)" 1 \
		"(got rc=$rc — expected 0; non-env stale key should not mask OAuth in auth.json)"
fi

# Assertion 4b.1 — Sourced credentials.sh-style variables are not process env.
# resolve_api_key sources credentials.sh into the helper process, leaving an
# OPENAI_API_KEY shell variable behind even though key_source is credentials:*.
# That variable must not be mistaken for an exported runtime env key.
OPENAI_API_KEY="[redacted-credential]"
_probe_check_oauth_fallback openai true "credentials:OPENAI_API_KEY"
rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "rejected-credentials-key+openai-oauth: sourced variable does not block OAuth fallback" 0
else
	print_result "rejected-credentials-key+openai-oauth: sourced variable does not block OAuth fallback" 1 \
		"(got rc=$rc — expected 0; sourced credentials variable should not mask OAuth)"
fi
unset OPENAI_API_KEY

# Assertion 4b.2 — OpenAI OAuth fallback must not mark healthy from type alone.
# GH#24636: after a rejected static key, openai.type == "oauth" in auth.json is
# insufficient unless the runtime has a refresh token or currently-live access.
cat >"$AUTH_FILE" <<JSON
{
  "openai": {
    "type": "oauth"
  }
}
JSON
_probe_check_oauth_fallback openai true "gopass:OPENAI_API_KEY"
rc=$?
if [[ "$rc" -eq 3 ]]; then
	print_result "openai-oauth-type-only: fallback fails closed (GH#24636)" 0
else
	print_result "openai-oauth-type-only: fallback fails closed (GH#24636)" 1 \
		"(got rc=$rc — expected 3; type-only auth.json must not record healthy)"
fi

# Assertion 4b.3 — A currently-live OpenAI OAuth access token is usable even
# without refresh, preserving runtime-compatible OAuth fallback when verified.
future_ms=$(($(date +%s) * 1000 + 3600000))
cat >"$AUTH_FILE" <<JSON
{
  "openai": {
    "type": "oauth",
    "access": "fake-openai-live-access-token",
    "expires": ${future_ms}
  }
}
JSON
_probe_check_oauth_fallback openai true "gopass:OPENAI_API_KEY"
rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "openai-oauth-live-access: verified fallback remains healthy" 0
else
	print_result "openai-oauth-live-access: verified fallback remains healthy" 1 \
		"(got rc=$rc — expected 0; live OAuth access should remain eligible)"
fi

# Assertion 4b.4 — date failures fail closed instead of producing arithmetic
# syntax errors while checking a live OpenAI OAuth access token.
cat >"$AUTH_FILE" <<JSON
{
  "openai": {
    "type": "oauth",
    "access": "fake-openai-live-access-token",
    "expires": ${future_ms}
  }
}
JSON
DATE_STUB_DIR="${TEST_ROOT}/date-stub"
mkdir -p "$DATE_STUB_DIR"
cat >"${DATE_STUB_DIR}/date" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${DATE_STUB_DIR}/date"
ORIGINAL_PATH="$PATH"
PATH="${DATE_STUB_DIR}:${PATH}"
_probe_check_oauth_fallback openai true "gopass:OPENAI_API_KEY" >/dev/null 2>&1
rc=$?
PATH="$ORIGINAL_PATH"
if [[ "$rc" -eq 3 ]]; then
	print_result "openai-oauth-live-access: date failure fails closed" 0
else
	print_result "openai-oauth-live-access: date failure fails closed" 1 \
		"(got rc=$rc — expected 3; invalid date output must not mark OAuth healthy)"
fi

# Assertion 4c — no OAuth in auth.json → fallback returns 3 (no override).
rm -f "$AUTH_FILE"
_probe_check_oauth_fallback openai true
rc=$?
if [[ "$rc" -eq 3 ]]; then
	print_result "stale-env-key+no-oauth: _probe_check_oauth_fallback returns 3 (no override)" 0
else
	print_result "stale-env-key+no-oauth: _probe_check_oauth_fallback returns 3 (no override)" 1 \
		"(got rc=$rc — expected 3; no auth.json OAuth should not produce a false healthy)"
fi

# Assertion 4d — OpenAI quota-specific 403 is unavailable, not auth fallback.
# GH#24595: OpenAI returns HTTP 403 for insufficient billing quota. The parser
# must classify that as quota_exceeded with a non-3 exit code so probe_provider
# cannot convert it to healthy via auth.json OAuth fallback.
quota_body='{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}'
parsed=$(_probe_parse_http_response openai 403 "$quota_body" true)
status=$(printf '%s\n' "$parsed" | sed -n '1p')
error_msg=$(printf '%s\n' "$parsed" | sed -n '2p')
exit_code=$(printf '%s\n' "$parsed" | sed -n '4p')
if [[ "$status" == "quota_exceeded" && "$error_msg" == "Quota exceeded (HTTP 403)" && "$exit_code" == "1" ]]; then
	print_result "openai-quota-403: parser returns quota_exceeded without OAuth fallback exit" 0
else
	print_result "openai-quota-403: parser returns quota_exceeded without OAuth fallback exit" 1 \
		"(got status='$status', error='$error_msg', exit=$exit_code — expected quota_exceeded / Quota exceeded / exit 1)"
fi

# Assertion 4e — generic 403 remains key_invalid and preserves existing t3229
# fallback eligibility for stale non-env keys.
auth_body='{"error":{"message":"Invalid API key","type":"invalid_request_error","code":"invalid_api_key"}}'
parsed=$(_probe_parse_http_response openai 403 "$auth_body" true)
status=$(printf '%s\n' "$parsed" | sed -n '1p')
exit_code=$(printf '%s\n' "$parsed" | sed -n '4p')
if [[ "$status" == "key_invalid" && "$exit_code" == "3" ]]; then
	print_result "openai-auth-403: parser preserves key_invalid fallback exit" 0
else
	print_result "openai-auth-403: parser preserves key_invalid fallback exit" 1 \
		"(got status='$status', exit=$exit_code — expected key_invalid / exit 3)"
fi
# =============================================================================
# Assertion 5 — ChatGPT OAuth denylist blocks known-unsupported pro models
# (GH#21990)
# =============================================================================
# _chatgpt_oauth_denylist_check must return 0 (denied) for known-unsupported
# pro models when auth.json shows openai.type == "oauth".
# It must return 1 (allowed) for supported models like gpt-5.5 even with OAuth.
# And it must return 1 (allowed) for any model when no OAuth is configured.

# Set up auth.json with OpenAI ChatGPT OAuth to trigger the denylist path.
cat >"$AUTH_FILE" <<JSON
{
  "openai": {
    "type": "oauth",
    "access": "fake-openai-chatgpt-access-token",
    "refresh": "fake-openai-chatgpt-refresh-token"
  }
}
JSON

# 5a — gpt-5.5-pro denied under ChatGPT OAuth
_chatgpt_oauth_denylist_check openai gpt-5.5-pro
rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "chatgpt-oauth-denylist: gpt-5.5-pro denied (rc=0)" 0
else
	print_result "chatgpt-oauth-denylist: gpt-5.5-pro denied (rc=0)" 1 \
		"(got rc=$rc — expected 0; gpt-5.5-pro should be blocked under ChatGPT OAuth)"
fi

# 5b — gpt-5.4-pro denied under ChatGPT OAuth
_chatgpt_oauth_denylist_check openai gpt-5.4-pro
rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "chatgpt-oauth-denylist: gpt-5.4-pro denied (rc=0)" 0
else
	print_result "chatgpt-oauth-denylist: gpt-5.4-pro denied (rc=0)" 1 \
		"(got rc=$rc — expected 0; gpt-5.4-pro should be blocked under ChatGPT OAuth)"
fi

# 5c — gpt-5.5 (non-pro) allowed under ChatGPT OAuth
_chatgpt_oauth_denylist_check openai gpt-5.5
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "chatgpt-oauth-denylist: gpt-5.5 allowed (rc=1)" 0
else
	print_result "chatgpt-oauth-denylist: gpt-5.5 allowed (rc=1)" 1 \
		"(got rc=$rc — expected 1; gpt-5.5 is supported and must not be blocked)"
fi

# 5d — denylist no-ops when no OAuth is present (API key auth)
rm -f "$AUTH_FILE"
_chatgpt_oauth_denylist_check openai gpt-5.5-pro
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "chatgpt-oauth-denylist: no-op without OAuth (rc=1)" 0
else
	print_result "chatgpt-oauth-denylist: no-op without OAuth (rc=1)" 1 \
		"(got rc=$rc — expected 1; denylist must not fire when auth.json has no OpenAI OAuth)"
fi

# 5e — denylist no-ops for non-openai provider
cat >"$AUTH_FILE" <<JSON
{
  "openai": {
    "type": "oauth",
    "access": "fake-openai-chatgpt-access-token",
    "refresh": "fake-openai-chatgpt-refresh-token"
  }
}
JSON
_chatgpt_oauth_denylist_check anthropic gpt-5.5-pro
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "chatgpt-oauth-denylist: no-op for non-openai provider (rc=1)" 0
else
	print_result "chatgpt-oauth-denylist: no-op for non-openai provider (rc=1)" 1 \
		"(got rc=$rc — expected 1; denylist only applies to openai provider)"
fi

rm -f "$AUTH_FILE"

# =============================================================================
# Summary
# =============================================================================
printf '\n%d test(s) run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
