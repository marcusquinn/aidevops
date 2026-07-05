#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${TEST_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headless-oauth-pool-gate.XXXXXX")"
HOME="$TMP_DIR/home"
mkdir -p "$HOME/.aidevops"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

print_error() { printf 'ERROR: %s\n' "$1" >&2; return 0; }
print_info() { printf 'INFO: %s\n' "$1" >&2; return 0; }
print_warning() { printf 'WARN: %s\n' "$1" >&2; return 0; }
timeout_sec() { return 1; }

OPENCODE_AUTH_FILE="$TMP_DIR/auth.json"
OPENCODE_BIN_DEFAULT="opencode"
OAUTH_POOL_HELPER="$TMP_DIR/oauth-pool-helper.sh"
DEFAULT_HEADLESS_MODELS="openai/gpt-5.5"
unset ANTHROPIC_API_KEY || true
unset OPENAI_API_KEY || true

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

TEST_MODELS=("openai/gpt-5.5" "anthropic/claude-sonnet-4-6")
cooldown="$(future_ms)"
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}},{\"email\":\"two@example.test\",\"status\":\"auth-error\",\"cooldownUntil\":${cooldown}}],\"anthropic\":[{\"email\":\"ok@example.test\",\"status\":\"active\",\"cooldownUntil\":0}]}"
actual="$(_choose_model_auto "worker" "sonnet")"
assert_equals "anthropic/claude-sonnet-4-6" "$actual" "all cooling OpenAI OAuth pool accounts are skipped" || true

cooldown="$(future_ms)"
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}},{\"email\":\"two@example.test\",\"status\":\"idle\",\"cooldownUntil\":0}]}"
actual="$(_choose_model_auto "worker" "sonnet")"
assert_equals "openai/gpt-5.5" "$actual" "one available OpenAI OAuth pool account keeps provider selectable" || true

cooldown="$(future_ms)"
OPENAI_API_KEY="static-test-key"
export OPENAI_API_KEY
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}}]}"
actual="$(_choose_model_auto "worker" "sonnet")"
assert_equals "openai/gpt-5.5" "$actual" "static OpenAI API key bypasses OAuth pool cooldown gate" || true
unset OPENAI_API_KEY

cooldown="$(future_ms)"
OPENAI_API_KEY="oauth-pool-access-token"
AIDEVOPS_OPENAI_API_KEY_SOURCE="oauth-pool"
export OPENAI_API_KEY AIDEVOPS_OPENAI_API_KEY_SOURCE
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"rate-limited\",\"cooldownUntil\":${cooldown}}],\"anthropic\":[{\"email\":\"ok@example.test\",\"status\":\"active\",\"cooldownUntil\":0}]}"
actual="$(_choose_model_auto "worker" "sonnet")"
assert_equals "anthropic/claude-sonnet-4-6" "$actual" "OAuth-injected OpenAI API key does not bypass OAuth pool cooldown gate" || true
unset OPENAI_API_KEY AIDEVOPS_OPENAI_API_KEY_SOURCE

rm -f "$HOME/.aidevops/oauth-pool.json"
actual="$(_choose_model_auto "worker" "sonnet")"
assert_equals "openai/gpt-5.5" "$actual" "missing OAuth pool remains non-blocking for legacy auth" || true

cooldown="$(past_ms)"
write_pool "{\"openai\":[{\"email\":\"one@example.test\",\"status\":\"idle\",\"cooldownUntil\":${cooldown}}]}"
actual="$(_choose_model_auto "worker" "sonnet")"
assert_equals "openai/gpt-5.5" "$actual" "expired cooldown does not block an otherwise idle account" || true

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d OAuth pool gate regression test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll OAuth pool gate tests passed\n'
exit 0
