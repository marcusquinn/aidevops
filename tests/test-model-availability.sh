#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-model-availability.sh
#
# Tests for model-availability-helper.sh (t132.3)
# Validates: syntax, help output, DB init, cache logic, tier resolution,
# local/ollama probe tests, and integration with supervisor resolve_model/check_model_health.
#
# Usage: bash tests/test-model-availability.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/model-availability-helper.sh"
SUPERVISOR="$REPO_DIR/.agents/scripts/supervisor-helper.sh"
VERBOSE="${1:-}"

# Portable timeout: gtimeout (macOS homebrew) > timeout (Linux) > none
TIMEOUT_CMD=""
if command -v gtimeout &>/dev/null; then
	TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
	TIMEOUT_CMD="timeout"
fi

# Run a command with optional timeout
run_with_timeout() {
	local secs="$1"
	shift
	if [[ -n "$TIMEOUT_CMD" ]]; then
		"$TIMEOUT_CMD" "$secs" "$@"
	else
		"$@"
	fi
}

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	fi
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	fi
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# Use a temp DB for testing to avoid polluting real cache
TEST_DB_DIR=$(mktemp -d)
export AVAILABILITY_DB_OVERRIDE="$TEST_DB_DIR/test-availability.db"
trap 'rm -rf "$TEST_DB_DIR"' EXIT

# ============================================================
# SECTION 1: Basic validation
# ============================================================
section "Basic Validation"

# Syntax check
if bash -n "$HELPER" 2>/dev/null; then
	pass "bash -n syntax check"
else
	fail "bash -n syntax check" "Script has syntax errors"
fi

# ShellCheck
if command -v shellcheck &>/dev/null; then
	sc_output=$(shellcheck "$HELPER" 2>&1 || true)
	sc_errors=$(echo "$sc_output" | grep -c "error" 2>/dev/null || true)
	if [[ "$sc_errors" -eq 0 ]]; then
		pass "shellcheck (0 errors)"
	else
		fail "shellcheck ($sc_errors errors)" "$(echo "$sc_output" | head -5)"
	fi
else
	skip "shellcheck not installed"
fi

# Help command
help_output=$(run_with_timeout 5 bash "$HELPER" help 2>&1) || true
if [[ -n "$help_output" ]]; then
	pass "help command produces output"
else
	fail "help command produces output" "No output"
fi

# Help mentions key commands
if echo "$help_output" | grep -qi "check"; then
	pass "help mentions 'check' command"
else
	fail "help mentions 'check' command"
fi

if echo "$help_output" | grep -qi "probe"; then
	pass "help mentions 'probe' command"
else
	fail "help mentions 'probe' command"
fi

if echo "$help_output" | grep -qi "resolve"; then
	pass "help mentions 'resolve' command"
else
	fail "help mentions 'resolve' command"
fi

if echo "$help_output" | grep -qi "rate-limits"; then
	pass "help mentions 'rate-limits' command"
else
	fail "help mentions 'rate-limits' command"
fi

# ============================================================
# SECTION 2: Status command (no prior data)
# ============================================================
section "Status Command (Empty State)"

status_output=$(run_with_timeout 5 bash "$HELPER" status 2>&1) || true
if [[ -n "$status_output" ]]; then
	pass "status command runs without error"
else
	fail "status command runs without error" "No output or error"
fi

# ============================================================
# SECTION 3: Resolve command (tier resolution)
# ============================================================
section "Tier Resolution"

# Test that resolve returns a model spec for known tiers (including local)
for tier in local haiku flash sonnet pro opus health eval coding; do
	resolve_output=$(run_with_timeout 15 bash "$HELPER" resolve "$tier" --quiet 2>&1) || true
	# Even without API keys, resolve should return the primary model
	# (it falls through to the primary when no probe is possible)
	if [[ -n "$resolve_output" && "$resolve_output" == *"/"* ]]; then
		pass "resolve $tier -> $resolve_output"
	else
		# May fail if no API keys configured - that's OK for CI
		skip "resolve $tier (no API keys or provider unavailable)"
	fi
done

# Test unknown tier (use || true to prevent set -e from aborting on expected failure)
if run_with_timeout 5 bash "$HELPER" resolve "nonexistent" --quiet >/dev/null 2>&1; then
	fail "resolve unknown tier returns error" "Expected non-zero exit"
else
	pass "resolve unknown tier returns error"
fi

# GH#7633: Verify opus/coding tiers never return opencode/ prefix for Anthropic models.
# OpenCode uses anthropic/ as the provider prefix — opencode/claude-* causes
# ProviderModelNotFoundError at dispatch time.
for tier in opus coding haiku sonnet health eval; do
	tier_exit=0
	tier_output=$(run_with_timeout 5 bash "$HELPER" resolve "$tier" --quiet 2>&1) || tier_exit=$?
	if [[ "$tier_exit" -ne 0 || -z "$tier_output" ]]; then
		skip "resolve $tier: unable to resolve in this environment (cannot validate GH#7633)"
	elif [[ "$tier_output" == opencode/claude-* ]]; then
		fail "resolve $tier: must not return opencode/claude-* prefix (GH#7633)" \
			"Got: $tier_output — OpenCode uses anthropic/ prefix for Anthropic models"
	else
		pass "resolve $tier: no opencode/claude-* prefix (GH#7633)"
	fi
done

# ============================================================
# SECTION 4: Check command
# ============================================================
section "Check Command"

# Check with unknown provider (use if to prevent set -e from aborting on expected failure)
if run_with_timeout 5 bash "$HELPER" check "nonexistent_provider_xyz" --quiet >/dev/null 2>&1; then
	fail "check unknown target returns error" "Expected non-zero exit, got 0"
else
	pass "check unknown target returns error"
fi

# Check with known provider (may succeed or fail depending on keys)
# Use || true to prevent set -e from aborting on non-zero exit
for provider in anthropic openai google opencode; do
	check_exit=0
	run_with_timeout 15 bash "$HELPER" check "$provider" --quiet >/dev/null 2>&1 || check_exit=$?
	case "$check_exit" in
	0) pass "check $provider: healthy" ;;
	1) pass "check $provider: unhealthy (expected without key or CLI)" ;;
	2) pass "check $provider: rate limited" ;;
	3) pass "check $provider: no key (expected in CI)" ;;
	*) fail "check $provider: unexpected exit code $check_exit" ;;
	esac
done

# local and ollama are no-key providers — graceful failure when server not running
for provider in local ollama; do
	check_exit=0
	run_with_timeout 10 bash "$HELPER" check "$provider" --quiet >/dev/null 2>&1 || check_exit=$?
	case "$check_exit" in
	0) pass "check $provider: healthy (server running)" ;;
	1) pass "check $provider: unhealthy (server not running — expected in CI)" ;;
	*) fail "check $provider: unexpected exit code $check_exit (expected 0 or 1)" ;;
	esac
done

# ============================================================
# SECTION 5: Invalidate command
# ============================================================
section "Cache Invalidation"

run_with_timeout 5 bash "$HELPER" invalidate >/dev/null 2>&1
invalidate_exit=$?
if [[ $invalidate_exit -eq 0 ]]; then
	pass "invalidate all caches"
else
	fail "invalidate all caches" "Exit code: $invalidate_exit"
fi

run_with_timeout 5 bash "$HELPER" invalidate anthropic >/dev/null 2>&1
invalidate_prov_exit=$?
if [[ $invalidate_prov_exit -eq 0 ]]; then
	pass "invalidate specific provider cache"
else
	fail "invalidate specific provider cache" "Exit code: $invalidate_prov_exit"
fi

# ============================================================
# SECTION 6: Supervisor integration
# ============================================================
section "Supervisor Integration"

# Verify supervisor references the availability helper
if grep -q "model-availability-helper.sh" "$SUPERVISOR"; then
	pass "supervisor references model-availability-helper.sh"
else
	fail "supervisor references model-availability-helper.sh"
fi

# Verify resolve_model() has availability helper fast path
if grep -q "availability_helper.*resolve" "$SUPERVISOR"; then
	pass "resolve_model() uses availability helper"
else
	fail "resolve_model() uses availability helper"
fi

# Verify check_model_health() has availability helper fast path
if grep -q "availability_helper.*check" "$SUPERVISOR"; then
	pass "check_model_health() uses availability helper fast path"
else
	fail "check_model_health() uses availability helper fast path"
fi

# Verify check_model_health() still has CLI fallback
if grep -q 'health-check' "$SUPERVISOR"; then
	pass "check_model_health() retains CLI fallback (slow path)"
else
	fail "check_model_health() retains CLI fallback (slow path)"
fi

# ============================================================
# SECTION 7: OpenCode Integration
# ============================================================
section "OpenCode Integration"

# Verify opencode is a known provider
if bash "$HELPER" help 2>&1 | grep -q "opencode"; then
	pass "help mentions opencode provider"
else
	fail "help mentions opencode provider"
fi

# Check opencode provider (should succeed if CLI installed, fail gracefully otherwise)
check_oc_exit=0
run_with_timeout 10 bash "$HELPER" check opencode --quiet >/dev/null 2>&1 || check_oc_exit=$?
case "$check_oc_exit" in
0) pass "check opencode: healthy (CLI and cache available)" ;;
1) pass "check opencode: unhealthy (CLI or cache not available)" ;;
*) fail "check opencode: unexpected exit code $check_oc_exit" ;;
esac

# Verify opencode model check (if opencode is available)
if command -v opencode &>/dev/null && [[ -f "$HOME/.cache/opencode/models.json" ]]; then
	oc_model_exit=0
	run_with_timeout 10 bash "$HELPER" check "opencode/claude-sonnet-4" --quiet >/dev/null 2>&1 || oc_model_exit=$?
	case "$oc_model_exit" in
	0) pass "check opencode/claude-sonnet-4: available" ;;
	1) pass "check opencode/claude-sonnet-4: not available (provider unhealthy)" ;;
	*) fail "check opencode/claude-sonnet-4: unexpected exit code $oc_model_exit" ;;
	esac
else
	skip "opencode model check (opencode CLI not installed)"
fi

# ============================================================
# SECTION 8: OpenCode Model ID Validation (GH#12470)
# ============================================================
section "OpenCode Model ID Validation (GH#12470)"

# Verify the pro tier no longer uses the stale gemini-3-pro model ID
if command -v opencode &>/dev/null && [[ -f "$HOME/.cache/opencode/models.json" ]]; then
	# Source the helper to access get_tier_models directly
	pro_tier_output=$(bash -c '
		source "'"$HELPER"'" 2>/dev/null
		get_tier_models "pro" 2>/dev/null
	' 2>/dev/null) || pro_tier_output=""

	if [[ -z "$pro_tier_output" ]]; then
		# Fallback: grep the source for the pro tier line in the opencode-available branch
		pro_tier_output=$(grep -A1 '_is_opencode_available' "$HELPER" | head -1 || true)
		# Just check the source directly
		if grep -q 'opencode/gemini-3-pro' "$HELPER"; then
			fail "pro tier still uses stale opencode/gemini-3-pro (GH#12470)"
		else
			pass "pro tier no longer uses stale opencode/gemini-3-pro (GH#12470)"
		fi
	else
		if echo "$pro_tier_output" | grep -q 'opencode/gemini-3-pro'; then
			fail "pro tier returns stale opencode/gemini-3-pro (GH#12470)" \
				"Got: $pro_tier_output"
		elif echo "$pro_tier_output" | grep -q 'opencode/gemini-3.1-pro'; then
			pass "pro tier uses correct opencode/gemini-3.1-pro (GH#12470)"
		else
			pass "pro tier uses non-opencode fallback (GH#12470): $pro_tier_output"
		fi
	fi

	# Verify all opencode/ model IDs in tier mappings exist in the models cache
	stale_models=""
	for tier in haiku flash sonnet pro opus health eval coding; do
		tier_line=$(grep "^[[:space:]]*${tier})" "$HELPER" | head -1 || true)
		# Extract opencode/ model IDs from the tier line
		oc_model=$(echo "$tier_line" | grep -oE 'opencode/[a-zA-Z0-9._-]+' || true)
		if [[ -n "$oc_model" ]]; then
			oc_model_id="${oc_model#opencode/}"
			if ! jq -e --arg m "$oc_model_id" '.opencode.models[$m] // empty' \
				"$HOME/.cache/opencode/models.json" >/dev/null 2>&1; then
				stale_models="${stale_models}${oc_model} (tier: ${tier}), "
			fi
		fi
	done

	if [[ -z "$stale_models" ]]; then
		pass "all opencode/ model IDs in tier mappings exist in models cache"
	else
		fail "stale opencode/ model IDs found in tier mappings" \
			"${stale_models%, }"
	fi

	# Verify _validate_opencode_model_id function exists
	if grep -q '_validate_opencode_model_id' "$HELPER"; then
		pass "_validate_opencode_model_id function exists"
	else
		fail "_validate_opencode_model_id function missing (GH#12470)"
	fi

	# Verify resolve_tier calls validation
	if grep -q '_validate_opencode_model_id.*primary\|_validate_opencode_model_id.*fallback' "$HELPER"; then
		pass "resolve_tier validates opencode model IDs before dispatch"
	else
		fail "resolve_tier does not validate opencode model IDs (GH#12470)"
	fi
else
	skip "opencode model ID validation (opencode CLI not installed)"
fi

# ============================================================
# SECTION 9: JSON output
# ============================================================
section "JSON Output"

# Status --json
json_status=$(run_with_timeout 5 bash "$HELPER" status --json 2>&1) || true
if echo "$json_status" | grep -q "{" 2>/dev/null; then
	pass "status --json produces JSON"
else
	skip "status --json (no data to format)"
fi

# Resolve --json
json_resolve=$(run_with_timeout 15 bash "$HELPER" resolve sonnet --json --quiet 2>&1) || true
if echo "$json_resolve" | grep -q "tier" 2>/dev/null; then
	pass "resolve --json produces JSON with tier field"
else
	skip "resolve --json (provider may be unavailable)"
fi

# ============================================================
# SECTION 10: Local / Ollama Probe Tests
# ============================================================
section "Local / Ollama Probe Tests"

# local provider: probe endpoint is http://localhost:8080/v1/models
# Graceful failure expected when no local inference server is running.
local_probe_exit=0
run_with_timeout 10 bash "$HELPER" probe local --quiet >/dev/null 2>&1 || local_probe_exit=$?
case "$local_probe_exit" in
0) pass "probe local: server running and healthy" ;;
1) pass "probe local: server not running (graceful failure — expected in CI)" ;;
*) fail "probe local: unexpected exit code $local_probe_exit (expected 0 or 1)" ;;
esac

# ollama provider: probe endpoint is http://localhost:11434/api/tags
# Graceful failure expected when Ollama is not running.
ollama_probe_exit=0
run_with_timeout 10 bash "$HELPER" probe ollama --quiet >/dev/null 2>&1 || ollama_probe_exit=$?
case "$ollama_probe_exit" in
0) pass "probe ollama: server running and healthy" ;;
1) pass "probe ollama: server not running (graceful failure — expected in CI)" ;;
*) fail "probe ollama: unexpected exit code $ollama_probe_exit (expected 0 or 1)" ;;
esac

# Verify local tier is in the tier resolution table (grep source directly)
# The helper calls main "$@" at the bottom so sourcing it is not safe;
# instead, grep the get_tier_models case statement for the local) entry.
if grep -q "^[[:space:]]*local)" "$HELPER"; then
	pass "local tier present in get_tier_models case statement"
else
	fail "local tier missing from get_tier_models case statement"
fi

# Verify local tier primary model uses local/ prefix (grep source for get_tier_models)
# get_tier_models has: local) echo "local/llama.cpp|..." ;;
# Check both the echo-on-next-line and inline-echo patterns.
local_tier_has_prefix=0
grep -A1 "^[[:space:]]*local)" "$HELPER" | grep -q 'echo.*local/' && local_tier_has_prefix=1
grep "^[[:space:]]*local)" "$HELPER" | grep -q 'local/' && local_tier_has_prefix=1
if [[ "$local_tier_has_prefix" -eq 1 ]]; then
	pass "local tier primary model uses local/ prefix"
else
	fail "local tier primary model should use local/ prefix" \
		"No 'local/' found in local) case of get_tier_models"
fi

# Verify ollama is a known provider in the helper (check help output or source)
ollama_in_help=0
bash "$HELPER" help 2>&1 | grep -q "ollama" && ollama_in_help=1
grep -q "ollama" "$HELPER" && ollama_in_help=1
if [[ "$ollama_in_help" -eq 1 ]]; then
	pass "ollama present in model-availability-helper.sh"
else
	fail "ollama not found in model-availability-helper.sh"
fi

# Verify local is a known provider in the helper
if grep -q '"local"' "$HELPER" || grep -q "local)" "$HELPER"; then
	pass "local provider present in model-availability-helper.sh source"
else
	fail "local provider not found in model-availability-helper.sh"
fi

# ============================================================
# SECTION 11: API Probe Parsing Regression (GH#17427)
# ============================================================
section "API Probe Parsing Regression (GH#17427)"

# Source a temp copy without the final main "$@" line so helper functions can be
# called directly while preserving SCRIPT_DIR-relative sourcing.
probe_helper_copy=$(mktemp "$REPO_DIR/.agents/scripts/model-availability-helper.test.XXXXXX")
sed '$d' "$HELPER" >"$probe_helper_copy"
probe_parse_output=$(bash -c '
	source "$1" 2>/dev/null || exit 1
	response=$'"'"'HTTP/2 200\ncontent-type: application/json\n\n{"data":[{"id":"m1"},{"id":"m2"}]}\n200\n0.209059'"'"'
	http_code=$(echo "$response" | tail -2 | head -1)
	body=$(echo "$response" | sed "1,/^$/d" | awk "NR>2{print buf[NR%2]} {buf[NR%2]=\$0}")
	parsed=$(_probe_parse_http_response "anthropic" "$http_code" "$body" true)
	printf "%s\n" "$http_code"
	printf "%s\n" "$body"
	printf "%s\n" "$parsed"
' bash "$probe_helper_copy" 2>/dev/null) || probe_parse_output=""
rm -f "$probe_helper_copy"

probe_http_code=$(printf '%s\n' "$probe_parse_output" | sed -n '1p')
probe_body=$(printf '%s\n' "$probe_parse_output" | sed -n '2p')
probe_status=$(printf '%s\n' "$probe_parse_output" | sed -n '3p')
probe_models=$(printf '%s\n' "$probe_parse_output" | sed -n '5p')
probe_exit=$(printf '%s\n' "$probe_parse_output" | sed -n '6p')

if [[ "$probe_http_code" == "200" ]]; then
	pass "probe_provider parses penultimate line as http_code (GH#17427)"
else
	fail "probe_provider parses penultimate line as http_code (GH#17427)" "Got: ${probe_http_code:-<empty>}"
fi

if [[ "$probe_body" == '{"data":[{"id":"m1"},{"id":"m2"}]}' ]]; then
	pass "probe_provider body extraction drops curl trailer lines"
else
	fail "probe_provider body extraction drops curl trailer lines" "Got: ${probe_body:-<empty>}"
fi

if [[ "$probe_status" == "healthy" && "$probe_models" == "2" && "$probe_exit" == "0" ]]; then
	pass "probe_provider parses HTTP 200 API probe as healthy (GH#17427)"
else
	fail "probe_provider parses HTTP 200 API probe as healthy (GH#17427)" \
		"status=${probe_status:-<empty>} models=${probe_models:-<empty>} exit=${probe_exit:-<empty>}"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
printf "  \033[1mResults: %d total, \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m, \033[0;33m%d skipped\033[0m\n" \
	"$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	echo ""
	printf "\033[0;31mFAILURES DETECTED - review output above\033[0m\n"
	exit 1
else
	echo ""
	printf "\033[0;32mAll tests passed.\033[0m\n"
	exit 0
fi
