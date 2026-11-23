#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${TEST_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headless-oauth-pool-gate.XXXXXX")"
HOME="$TMP_DIR/home"
mkdir -p "$HOME/.aidevops" "$HOME/.local/share/opencode"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

print_error() { printf 'ERROR: %s\n' "$1" >&2; return 0; }
print_info() { printf 'INFO: %s\n' "$1" >&2; return 0; }
print_warning() { printf 'WARN: %s\n' "$1" >&2; return 0; }
timeout_sec() { return 1; }

OPENCODE_AUTH_FILE="$HOME/.local/share/opencode/auth.json"
OPENCODE_BIN_DEFAULT="opencode"
OAUTH_POOL_HELPER="$TMP_DIR/oauth-pool-helper.sh"
DEFAULT_HEADLESS_MODELS="openai/gpt-5.5"
unset ANTHROPIC_API_KEY || true
unset OPENAI_API_KEY || true
unset AIDEVOPS_OPENAI_API_KEY_SOURCE || true
unset AIDEVOPS_ANTHROPIC_API_KEY_SOURCE || true

# shellcheck source=/dev/null
source "${AGENTS_SCRIPTS}/headless-runtime-provider.sh"
# shellcheck source=/dev/null
source "${AGENTS_SCRIPTS}/headless-runtime-model.sh"

failures=0

assert_equals() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$message" "$expected" "$actual" >&2
		failures=$((failures + 1))
		return 1
	fi
	printf 'PASS: %s\n' "$message"
	return 0
}

get_configured_models() {
	printf '%s\n' "${TEST_MODELS[@]}"
	return 0
}

get_last_provider() {
	printf '%s' ""
	return 0
}

set_last_provider() {
	local role="$1"
	local provider="$2"
	: "$role" "$provider"
	return 0
}

provider_auth_available() {
	local provider="$1"
	: "$provider"
	return 0
}

model_backoff_active() {
	local model="$1"
	: "$model"
	return 1
}

_choose_model_tier_downgrade() {
	local current_model="$1"
	: "$current_model"
	return 0
}

write_pool() {
	local body="$1"
	printf '%s\n' "$body" >"$HOME/.aidevops/oauth-pool.json"
	return 0
}

future_ms() {
	python3 - <<'PY'
import time
print(int(time.time() * 1000) + 3600_000)
PY
	return 0
}

past_ms() {
	python3 - <<'PY'
import time
print(int(time.time() * 1000) - 3600_000)
PY
	return 0
}

TEST_MODELS=("openai/gpt-5.5" "anthropic/claude-sonnet-5-5")
cooldown="$(future_ms)"
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}},{\"email\":\"two@example.test\",\"status\":\"auth-error\",\"cooldownUntil\":${cooldown}}],\"anthropic\":[{\"email\":\"ok@example.test\",\"status\":\"active\",\"cooldownUntil\":0}]}"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "anthropic/claude-sonnet-5-5" "$actual" "all cooling OpenAI OAuth pool accounts are skipped" || true

cooldown="$(future_ms)"
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}},{\"email\":\"two@example.test\",\"status\":\"idle\",\"cooldownUntil\":0}]}"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "openai/gpt-5.5" "$actual" "one available OpenAI OAuth pool account keeps provider selectable" || true

cooldown="$(future_ms)"
OPENAI_API_KEY="static-test-key"
export OPENAI_API_KEY
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}}]}"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "openai/gpt-5.5" "$actual" "static OpenAI API key bypasses OAuth pool cooldown gate" || true
unset OPENAI_API_KEY

cooldown="$(future_ms)"
OPENAI_API_KEY="oauth-pool-access-token"
AIDEVOPS_OPENAI_API_KEY_SOURCE="oauth-pool"
export OPENAI_API_KEY AIDEVOPS_OPENAI_API_KEY_SOURCE
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}}],\"anthropic\":[{\"email\":\"ok@example.test\",\"status\":\"active\",\"cooldownUntil\":0}]}"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "anthropic/claude-sonnet-5-5" "$actual" "OAuth-injected OpenAI API key does not bypass OAuth pool cooldown gate" || true
unset OPENAI_API_KEY AIDEVOPS_OPENAI_API_KEY_SOURCE

# GH#36707: an inherited pool-derived Anthropic env token must not pin
# selection to an exhausted pool; a genuinely independent key still bypasses.
TEST_MODELS=("anthropic/claude-sonnet-5-5" "openai/gpt-5.5")
cooldown="$(future_ms)"
ANTHROPIC_API_KEY="test-inherited-token"
AIDEVOPS_ANTHROPIC_API_KEY_SOURCE="oauth-pool"
export ANTHROPIC_API_KEY AIDEVOPS_ANTHROPIC_API_KEY_SOURCE
write_pool "{\"anthropic\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}}],\"openai\":[{\"email\":\"ok@example.test\",\"status\":\"active\",\"cooldownUntil\":0}]}"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "openai/gpt-5.5" "$actual" "inherited pool-derived Anthropic key falls back from exhausted pool" || true
unset AIDEVOPS_ANTHROPIC_API_KEY_SOURCE
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "anthropic/claude-sonnet-5-5" "$actual" "independent Anthropic API key bypasses OAuth pool cooldown gate" || true
unset ANTHROPIC_API_KEY
TEST_MODELS=("openai/gpt-5.5" "anthropic/claude-sonnet-5-5")

# GH#39947: stored API keys are independent of the OAuth pool, for both
# providers. Reject OAuth, missing/empty/non-string keys and malformed stores.
for provider in openai anthropic; do
	write_pool "{\"${provider}\":[{\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}}]}"
	for entry in '{"type":"api","key":"test-independent-key"}' \
		'{"type":"oauth","access":"test-access","refresh":"test-refresh","key":"test-key"}' \
		'{"type":"api","key":""}' '{"type":"api"}' \
		'{"type":"api","key":false}' '{"type":"api","key":123}' \
		'{"key":"test-key"}' 'null'; do
		printf '{"%s":%s}\n' "$provider" "$entry" >"$OPENCODE_AUTH_FILE"
		expected=1
		[[ "$entry" == '{"type":"api","key":"test-independent-key"}' ]] && expected=0
		rc=0
		provider_static_auth_available "$provider" || rc=$?
		assert_equals "$expected" "$rc" "$provider static auth validates stored entry $entry" || true
		rc=0
		provider_oauth_pool_available "$provider" || rc=$?
		assert_equals "$expected" "$rc" "$provider pool gate validates stored entry $entry" || true
	done
	printf '%s\n' 'not-json' >"$OPENCODE_AUTH_FILE"
	rc=0
	provider_static_auth_available "$provider" || rc=$?
	assert_equals "1" "$rc" "$provider malformed auth store is not static auth" || true
	printf '[]\n' >"$OPENCODE_AUTH_FILE"
	rc=0
	provider_static_auth_available "$provider" || rc=$?
	assert_equals "1" "$rc" "$provider non-object auth store is not static auth" || true

	printf '{"%s":{"type":"api","key":"test-independent-key"}}\n' "$provider" >"$OPENCODE_AUTH_FILE"
	model="openai/gpt-5.5"
	[[ "$provider" == "anthropic" ]] && model="anthropic/claude-sonnet-5-5"
	TEST_MODELS=("$model")
	actual="$(_choose_model_auto "worker" "standard")" || actual=""
	assert_equals "$model" "$actual" "$provider stored API key keeps auto selection available with exhausted pool" || true
	rc=0
	actual=$(HOME="$HOME" AIDEVOPS_OPENCODE_PROFILE=v1 \
		AIDEVOPS_HEADLESS_RUNTIME_DIR="$TMP_DIR/runtime-$provider" \
		AIDEVOPS_SKIP_CANARY_NEG_CACHE=1 \
		bash "$AGENTS_SCRIPTS/headless-runtime-helper.sh" select --model "$model") || rc=$?
	assert_equals "0" "$rc" "$provider CLI select succeeds with stored API key and exhausted pool" || true
	assert_equals "$model" "$actual" "$provider CLI select returns requested model" || true
done
rm -f "$OPENCODE_AUTH_FILE"
TEST_MODELS=("openai/gpt-5.5" "anthropic/claude-sonnet-5-5")

rm -f "$HOME/.aidevops/oauth-pool.json"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "openai/gpt-5.5" "$actual" "missing OAuth pool remains non-blocking for legacy auth" || true

cooldown="$(past_ms)"
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"idle\",\"cooldownUntil\":${cooldown}}]}"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "openai/gpt-5.5" "$actual" "expired cooldown does not block an otherwise idle account" || true

# GH#39936: only the plugin rewrites an expired "rate-limited" status, and only
# inside a session; a headless-only runner must recover when limits reset.
cooldown="$(past_ms)"
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}}]}"
actual="$(_choose_model_auto "worker" "standard")"
assert_equals "openai/gpt-5.5" "$actual" "rate-limited account with an expired cooldown recovers" || true

write_pool '{"openai":[{"email":"one@example.test","status":"active"}]}'
fingerprint_one="$(oauth_pool_account_set_fingerprint openai)"
write_pool '{"openai":[{"email":"one@example.test","status":"rate-limited"},{"email":"two@example.test","status":"active"}]}'
fingerprint_two="$(oauth_pool_account_set_fingerprint openai)"
write_pool '{"openai":[{"email":"one@example.test","status":"rate-limited","cooldownUntil":1}]}'
fingerprint_status="$(oauth_pool_account_set_fingerprint openai)"
[[ -n "$fingerprint_one" && "$fingerprint_one" != "$fingerprint_two" ]] && rc=0 || rc=1
assert_equals "0" "$rc" "adding a pool account changes the auth-signature pool fingerprint" || true
[[ "$fingerprint_one" == "$fingerprint_status" ]] && rc=0 || rc=1
assert_equals "0" "$rc" "account status changes do not churn the pool fingerprint" || true

# GH#39475: opencode2_oauth_pool_auth_available shares the availability rule.
# auth.json is absent (OPENCODE_AUTH_FILE points at a missing file).
write_pool '{"anthropic":[{"status":"billing-error","cooldownUntil":0}]}'
rc=0
AIDEVOPS_OPENCODE_PROFILE=v1 opencode2_oauth_pool_auth_available anthropic || rc=$?
assert_equals "1" "$rc" "billing-error-only pool is rejected by headless check" || true

write_pool '{"anthropic":[{"status":"active"}]}'
rc=0
AIDEVOPS_OPENCODE_PROFILE=v1 opencode2_oauth_pool_auth_available anthropic || rc=$?
assert_equals "0" "$rc" "active account is accepted by headless check" || true

mkdir -p "$TMP_DIR/v2root/auth"
printf '%s\n' '{"anthropic":[{"status":"idle"}]}' >"$TMP_DIR/v2root/auth/oauth-pool.json"
rc=0
AIDEVOPS_OPENCODE_PROFILE=v2 AIDEVOPS_OPENCODE_V2_ROOT="$TMP_DIR/v2root" opencode2_oauth_pool_auth_available anthropic || rc=$?
assert_equals "0" "$rc" "v2 profile reads AIDEVOPS_OPENCODE_V2_ROOT pool" || true

printf '{}' >"$OPENCODE_AUTH_FILE"
rc=0
AIDEVOPS_OPENCODE_PROFILE=v1 opencode2_oauth_pool_auth_available anthropic || rc=$?
assert_equals "1" "$rc" "pool ignored when auth.json exists" || true
rm -f "$OPENCODE_AUTH_FILE"

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d OAuth pool gate regression test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll OAuth pool gate tests passed\n'
exit 0
