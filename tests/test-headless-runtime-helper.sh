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
# Set a known model list so tests are self-contained and don't depend on
# the user's environment. Includes two providers for rotation/fallback tests.
export AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,openai/gpt-5.3-codex"
# Disable sandbox for tests — the sandbox strips env vars (STUB_*) needed
# by the opencode stub, causing test failures.
export AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1
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
	# Model-level backoff: key is the full model ID (e.g. openai/gpt-5.3-codex),
	# not just the provider name. Check for provider_error in the backoff state.
	if [[ "$backoff_state" == *"provider_error|"* ]]; then
		pass "zero-activity success is rejected"
	else
		fail "zero-activity success is rejected" "missing provider_error backoff state: $backoff_state"
	fi
fi
unset STUB_EMIT_ACTIVITY

section "Model-Level Backoff"
# Clear all backoff state for a clean test
bash "$HELPER" backoff clear anthropic >/dev/null 2>&1 || true
bash "$HELPER" backoff clear anthropic/claude-sonnet-4-6 >/dev/null 2>&1 || true
bash "$HELPER" backoff clear anthropic/claude-opus-4-6 >/dev/null 2>&1 || true
bash "$HELPER" backoff clear openai >/dev/null 2>&1 || true

# Configure two Anthropic models: sonnet + opus
# Back off sonnet (rate limit) — opus should still be available
AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
	bash "$HELPER" backoff set anthropic/claude-sonnet-4-6 rate_limit 3600 >/dev/null
model_after_sonnet_backoff=$(
	AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
		bash "$HELPER" select --role worker 2>/dev/null || true
)
if [[ "$model_after_sonnet_backoff" == "anthropic/claude-opus-4-6" ]]; then
	pass "sonnet rate-limited: opus still available from same provider"
else
	fail "sonnet rate-limited: opus still available from same provider" "got: $model_after_sonnet_backoff"
fi

# Back off opus too — now all models should be backed off
AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
	bash "$HELPER" backoff set anthropic/claude-opus-4-6 rate_limit 3600 >/dev/null
all_backed_off=$(
	AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
		bash "$HELPER" select --role worker 2>/dev/null || true
)
if [[ -z "$all_backed_off" ]]; then
	pass "both models backed off: no model available"
else
	fail "both models backed off: no model available" "got: $all_backed_off"
fi

# Clear sonnet backoff — sonnet should be available again
AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
	bash "$HELPER" backoff clear anthropic/claude-sonnet-4-6 >/dev/null
model_after_clear=$(
	AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
		bash "$HELPER" select --role worker 2>/dev/null || true
)
if [[ "$model_after_clear" == "anthropic/claude-sonnet-4-6" ]]; then
	pass "cleared sonnet backoff: sonnet available again"
else
	fail "cleared sonnet backoff: sonnet available again" "got: $model_after_clear"
fi

section "Auth Error Backs Off Provider"
# Clear all backoff state
bash "$HELPER" backoff clear anthropic >/dev/null 2>&1 || true
bash "$HELPER" backoff clear anthropic/claude-sonnet-4-6 >/dev/null 2>&1 || true
bash "$HELPER" backoff clear anthropic/claude-opus-4-6 >/dev/null 2>&1 || true

# Auth error should back off at provider level, blocking all models
AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
	bash "$HELPER" backoff set anthropic auth_error 3600 >/dev/null
auth_backoff_model=$(
	AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6" \
		bash "$HELPER" select --role worker 2>/dev/null || true
)
if [[ -z "$auth_backoff_model" ]]; then
	pass "auth error backs off all models from provider"
else
	fail "auth error backs off all models from provider" "got: $auth_backoff_model"
fi
# Clean up
bash "$HELPER" backoff clear anthropic >/dev/null 2>&1 || true

section "OpenCode Gateway Models"
# opencode/* models should be selectable when configured and auth file exists
# Create a fake auth file so provider_auth_available("opencode") returns true
FAKE_AUTH_DIR="$TEST_TMP_DIR/fake-opencode-home/.local/share/opencode"
mkdir -p "$FAKE_AUTH_DIR"
echo '{"token":"fake"}' >"$FAKE_AUTH_DIR/auth.json"

gateway_model=$(
	HOME="$TEST_TMP_DIR/fake-opencode-home" \
		AIDEVOPS_HEADLESS_MODELS="opencode/minimax-m2.5-free" \
		bash "$HELPER" select --role worker 2>/dev/null || true
)
if [[ "$gateway_model" == "opencode/minimax-m2.5-free" ]]; then
	pass "opencode/* gateway model is selectable when configured"
else
	fail "opencode/* gateway model is selectable when configured" "got: $gateway_model"
fi

# opencode/* models should be skipped when no auth file exists
# Use ANTHROPIC_API_KEY so Anthropic passes auth check even with fake HOME
no_auth_gateway=$(
	HOME="$TEST_TMP_DIR/no-auth-home" \
		ANTHROPIC_API_KEY="test-key" \
		AIDEVOPS_HEADLESS_MODELS="opencode/minimax-m2.5-free,anthropic/claude-sonnet-4-6" \
		bash "$HELPER" select --role worker 2>/dev/null || true
)
if [[ "$no_auth_gateway" == "anthropic/claude-sonnet-4-6" ]]; then
	pass "opencode/* skipped when no auth, falls back to next provider"
else
	fail "opencode/* skipped when no auth, falls back to next provider" "got: $no_auth_gateway"
fi

# opencode/* models should work in cmd_run dispatch
rm -f "$STUB_LOG_FILE"
export STUB_SESSION_ID="ses_gateway_one"
HOME="$TEST_TMP_DIR/fake-opencode-home" \
	AIDEVOPS_HEADLESS_MODELS="opencode/minimax-m2.5-free" \
	bash "$HELPER" run \
	--role worker \
	--session-key issue-gateway \
	--dir "$REPO_DIR" \
	--title "Issue Gateway" \
	--prompt "Reply with exactly OK" >/dev/null
if [[ -f "$STUB_LOG_FILE" ]] && grep -q 'opencode/minimax-m2.5-free' "$STUB_LOG_FILE"; then
	pass "opencode/* gateway model dispatches via cmd_run"
else
	fail "opencode/* gateway model dispatches via cmd_run" "stub log: $(cat "$STUB_LOG_FILE" 2>/dev/null || echo 'missing')"
fi

# Explicit --model with opencode/* should work (no longer rejected)
explicit_gateway=$(
	HOME="$TEST_TMP_DIR/fake-opencode-home" \
		bash "$HELPER" select --role worker --model opencode/minimax-m2.5-free 2>/dev/null || true
)
if [[ "$explicit_gateway" == "opencode/minimax-m2.5-free" ]]; then
	pass "explicit --model opencode/* is accepted"
else
	fail "explicit --model opencode/* is accepted" "got: $explicit_gateway"
fi

section "Session-Key Dedup Guard (GH#6538)"
# Test 1: A second run with the same session-key while the first is "running"
# should be blocked. Simulate by writing a lock file with our own PID (which
# is alive), then attempting a run with the same session-key.
LOCK_DIR="$TEST_TMP_DIR/runtime/locks"
mkdir -p "$LOCK_DIR"
echo "$$" >"$LOCK_DIR/issue-dedup-test.pid"
rm -f "$STUB_LOG_FILE"
AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic bash "$HELPER" run \
	--role worker \
	--session-key "issue-dedup-test" \
	--dir "$REPO_DIR" \
	--title "Issue #999: Dedup test" \
	--prompt "Reply with exactly OK" >/dev/null 2>&1 || true
if [[ -f "$STUB_LOG_FILE" ]]; then
	fail "dedup guard blocks second dispatch with same session-key" "stub was invoked (opencode ran)"
else
	pass "dedup guard blocks second dispatch with same session-key"
fi
rm -f "$LOCK_DIR/issue-dedup-test.pid"

# Test 2: A stale lock (dead PID) should be cleaned up and the run should proceed.
echo "99999999" >"$LOCK_DIR/issue-stale-test.pid"
rm -f "$STUB_LOG_FILE"
export STUB_SESSION_ID="ses_stale_lock"
AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic bash "$HELPER" run \
	--role worker \
	--session-key "issue-stale-test" \
	--dir "$REPO_DIR" \
	--title "Issue #998: Stale lock test" \
	--prompt "Reply with exactly OK" >/dev/null 2>&1
if [[ -f "$STUB_LOG_FILE" ]] && grep -q 'Reply with exactly OK' "$STUB_LOG_FILE"; then
	pass "stale lock (dead PID) is cleaned up and run proceeds"
else
	fail "stale lock (dead PID) is cleaned up and run proceeds" "stub log: $(cat "$STUB_LOG_FILE" 2>/dev/null || echo 'missing')"
fi

# Test 3: Lock file should be cleaned up after a successful run.
if [[ -f "$LOCK_DIR/issue-stale-test.pid" ]]; then
	fail "lock file cleaned up after successful run" "lock file still exists"
else
	pass "lock file cleaned up after successful run"
fi

# Test 4: Different session-keys should not block each other.
echo "$$" >"$LOCK_DIR/issue-other.pid"
rm -f "$STUB_LOG_FILE"
export STUB_SESSION_ID="ses_different_key"
AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic bash "$HELPER" run \
	--role worker \
	--session-key "issue-different" \
	--dir "$REPO_DIR" \
	--title "Issue #997: Different key" \
	--prompt "Reply with exactly OK" >/dev/null 2>&1
if [[ -f "$STUB_LOG_FILE" ]] && grep -q 'Reply with exactly OK' "$STUB_LOG_FILE"; then
	pass "different session-keys do not block each other"
else
	fail "different session-keys do not block each other" "stub log: $(cat "$STUB_LOG_FILE" 2>/dev/null || echo 'missing')"
fi
rm -f "$LOCK_DIR/issue-other.pid"

echo ""
printf "Total: %d, Passed: %d, Failed: %d\n" "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
	exit 0
fi
exit 1
