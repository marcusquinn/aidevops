#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/headless-runtime-helper.sh"
VERBOSE="${1:-}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  PASS %s\n" "$message"
	fi
	return 0
}

fail() {
	local message="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  FAIL %s\n" "$message"
	if [[ -n "$detail" ]]; then
		printf "       %s\n" "$detail"
	fi
	return 0
}

section() {
	local title="$1"
	echo ""
	printf "=== %s ===\n" "$title"
	return 0
}

TEST_TMP_DIR=$(mktemp -d)
export AIDEVOPS_HEADLESS_RUNTIME_DIR="$TEST_TMP_DIR/runtime"
export STUB_LOG_FILE="$TEST_TMP_DIR/opencode-args.log"
# Provide a fake OpenAI API key so provider_auth_available("openai") returns true
# in tests that exercise OpenAI model selection. Tests for the no-auth path
# explicitly unset this and remove the auth file.
export OPENAI_API_KEY="test-key-for-provider-auth-check"

cleanup() {
	rm -rf "$TEST_TMP_DIR"
	return 0
}
trap cleanup EXIT

cat >"$TEST_TMP_DIR/opencode-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_LOG_FILE}"
session_id="${STUB_SESSION_ID:-ses_stub_default}"
text="${STUB_TEXT:-OK}"
emit_activity="${STUB_EMIT_ACTIVITY:-1}"
if [[ "$emit_activity" != "1" ]]; then
	exit 0
fi
cat <<JSON
{"type":"step_start","sessionID":"${session_id}","part":{"sessionID":"${session_id}"}}
{"type":"text","sessionID":"${session_id}","part":{"sessionID":"${session_id}","text":"${text}"}}
JSON
exit 0
STUB
chmod +x "$TEST_TMP_DIR/opencode-stub.sh"
export OPENCODE_BIN="$TEST_TMP_DIR/opencode-stub.sh"

section "Syntax"
if bash -n "$HELPER"; then
	pass "bash -n"
else
	fail "bash -n" "syntax error"
fi

section "Selection Defaults"
first_model=$(bash "$HELPER" select --role worker 2>/dev/null || true)
second_model=$(bash "$HELPER" select --role worker 2>/dev/null || true)
if [[ "$first_model" == "anthropic/claude-sonnet-4-6" ]]; then
	pass "first selection uses anthropic default"
else
	fail "first selection uses anthropic default" "got: $first_model"
fi
if [[ "$second_model" == "openai/gpt-5.3-codex" ]]; then
	pass "second selection alternates to openai"
else
	fail "second selection alternates to openai" "got: $second_model"
fi

section "Allowlist"
allowlisted_model=$(AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" select --role worker 2>/dev/null || true)
if [[ "$allowlisted_model" == "openai/gpt-5.3-codex" ]]; then
	pass "openai allowlist restricts selection"
else
	fail "openai allowlist restricts selection" "got: $allowlisted_model"
fi

section "Auth Pre-check"
# When OpenAI has no auth configured, Codex must be skipped silently (no error,
# no backoff recorded). The selection should fall back to Anthropic.
no_auth_model=$(
	unset OPENAI_API_KEY
	AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI="" \
		bash "$HELPER" select --role worker 2>/dev/null || true
)
if [[ "$no_auth_model" == "anthropic/claude-sonnet-4-6" ]]; then
	pass "no OpenAI auth: Codex skipped silently, Anthropic selected"
else
	fail "no OpenAI auth: Codex skipped silently, Anthropic selected" "got: $no_auth_model"
fi
# Verify no backoff was recorded for openai (silent skip, not a failure)
no_auth_backoff=$(
	unset OPENAI_API_KEY
	AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI="" \
		bash "$HELPER" backoff status 2>/dev/null || true
)
if [[ "$no_auth_backoff" != *"openai|"* ]]; then
	pass "no OpenAI auth: no backoff recorded (silent skip)"
else
	fail "no OpenAI auth: no backoff recorded (silent skip)" "backoff state: $no_auth_backoff"
fi
# Restore OpenAI auth for subsequent tests
export OPENAI_API_KEY="test-key-for-provider-auth-check"

section "Backoff"
bash "$HELPER" backoff set anthropic rate_limit 3600 >/dev/null
post_backoff_model=$(bash "$HELPER" select --role pulse 2>/dev/null || true)
if [[ "$post_backoff_model" == "openai/gpt-5.3-codex" ]]; then
	pass "backed off anthropic is skipped"
else
	fail "backed off anthropic is skipped" "got: $post_backoff_model"
fi

if bash "$HELPER" backoff set anthropic rate_limit '10;rm -rf /' >/dev/null 2>&1; then
	fail "invalid retry_seconds is rejected" "helper accepted a non-numeric retry_seconds"
else
	pass "invalid retry_seconds is rejected"
fi

section "Auth Change Clears Backoff"
export AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI="sig-old"
bash "$HELPER" backoff set openai auth_error 3600 >/dev/null
export AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai
export AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI="sig-new"
recovered_model=$(bash "$HELPER" select --role pulse 2>/dev/null || true)
if [[ "$recovered_model" == "openai/gpt-5.3-codex" ]]; then
	pass "auth signature change clears backoff"
else
	fail "auth signature change clears backoff" "got: $recovered_model"
fi
unset AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST

section "Session Persistence"
export STUB_SESSION_ID="ses_openai_one"
rm -f "$STUB_LOG_FILE"
AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" run \
	--role worker \
	--session-key issue-101 \
	--dir "$REPO_DIR" \
	--title "Issue #101" \
	--prompt "Reply with exactly OK" >/dev/null
export STUB_SESSION_ID="ses_openai_two"
AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" run \
	--role worker \
	--session-key issue-101 \
	--dir "$REPO_DIR" \
	--title "Issue #101" \
	--prompt "Reply with exactly OK" >/dev/null

if grep -q -- '--session ses_openai_one --continue' "$STUB_LOG_FILE"; then
	pass "second run reuses persisted provider session"
else
	fail "second run reuses persisted provider session" "logged args: $(tr '\n' ' ' <"$STUB_LOG_FILE")"
fi

section "Pulse Runs Stay Fresh"
export STUB_SESSION_ID="ses_pulse_one"
rm -f "$STUB_LOG_FILE"
AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" run \
	--role pulse \
	--session-key supervisor-pulse \
	--dir "$REPO_DIR" \
	--title "Supervisor Pulse" \
	--prompt "/pulse" >/dev/null
export STUB_SESSION_ID="ses_pulse_two"
AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" run \
	--role pulse \
	--session-key supervisor-pulse \
	--dir "$REPO_DIR" \
	--title "Supervisor Pulse" \
	--prompt "/pulse" >/dev/null

if grep -q -- '--session ' "$STUB_LOG_FILE"; then
	fail "pulse runs do not reuse persisted sessions" "logged args: $(tr '\n' ' ' <"$STUB_LOG_FILE")"
else
	pass "pulse runs do not reuse persisted sessions"
fi

section "Zero Activity Success Is Rejected"
export STUB_EMIT_ACTIVITY="0"
if AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai bash "$HELPER" run \
	--role worker \
	--session-key issue-202 \
	--dir "$REPO_DIR" \
	--title "Issue #202" \
	--prompt "Reply with exactly OK" >/dev/null 2>&1; then
	fail "zero-activity success is rejected" "helper accepted a run with no model activity"
else
	backoff_state=$(bash "$HELPER" backoff status 2>/dev/null || true)
	if [[ "$backoff_state" == *"openai|provider_error|"* ]]; then
		pass "zero-activity success is rejected"
	else
		fail "zero-activity success is rejected" "missing provider_error backoff state: $backoff_state"
	fi
fi
unset STUB_EMIT_ACTIVITY

echo ""
printf "Total: %d, Passed: %d, Failed: %d\n" "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
	exit 0
fi
exit 1
