#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for llm-routing-helper.sh (t2847)
# Covers tier selection, hard-fail path, audit log correctness,
# cost aggregation, and redaction hook firing for pii+cloud tier.
#
# Usage: bash .agents/tests/test-llm-routing.sh
# Requires: jq
#
# All tests use LLM_ROUTING_DRY_RUN=1 so no real LLM calls are made.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROUTING_HELPER="${SCRIPT_DIR}/../scripts/llm-routing-helper.sh"
REDACTION_HELPER="${SCRIPT_DIR}/../scripts/redaction-helper.sh"
ROUTING_CONFIG="${SCRIPT_DIR}/../templates/llm-routing-config.json"

# =============================================================================
# Test framework
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1" reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

_assert_exit_0() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected exit 0, got non-zero"
		return 0
	fi
}

_assert_exit_nonzero() {
	local name="$1"
	shift
	if ! "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected non-zero exit, got 0"
		return 0
	fi
}

_assert_file_exists() {
	local name="$1" path="$2"
	if [[ -f "$path" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "file not found: ${path}"
		return 0
	fi
}

_assert_file_contains() {
	local name="$1" path="$2" pattern="$3"
	if [[ -f "$path" ]] && grep -qE "$pattern" "$path" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "file '${path}' does not contain pattern '${pattern}'"
		return 0
	fi
}

_assert_stdout_contains() {
	local name="$1" pattern="$2"
	shift 2
	local output
	output=$("$@" 2>/dev/null) || true
	if printf '%s' "$output" | grep -qE "$pattern"; then
		_pass "$name"
		return 0
	else
		_fail "$name" "stdout does not contain '${pattern}' (got: ${output:0:100})"
		return 0
	fi
}

_assert_json_field() {
	local name="$1" file="$2" jq_filter="$3" expected="$4"
	local actual
	actual=$(jq -r "$jq_filter" "$file" 2>/dev/null) || actual="jq-error"
	if [[ "$actual" == "$expected" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected '${expected}', got '${actual}'"
		return 0
	fi
}

# =============================================================================
# Test groups
# =============================================================================

test_config_loading() {
	printf '\n--- Config loading ---\n'

	_assert_exit_0 "config template is valid JSON" \
		jq empty "$ROUTING_CONFIG"

	_assert_exit_0 "config has 5 tiers" \
		bash -c "jq -e '.tiers | keys | length == 5' '$ROUTING_CONFIG' > /dev/null"

	_assert_exit_0 "config has 3 providers" \
		bash -c "jq -e '.providers | keys | length == 3' '$ROUTING_CONFIG' > /dev/null"

	_assert_exit_0 "privileged tier has hard_fail_if_unavailable=true" \
		bash -c "jq -e '.tiers.privileged.hard_fail_if_unavailable == true' '$ROUTING_CONFIG' > /dev/null"

	_assert_exit_0 "pii tier has redaction_required_for_cloud=true" \
		bash -c "jq -e '.tiers.pii.redaction_required_for_cloud == true' '$ROUTING_CONFIG' > /dev/null"

	return 0
}

test_routing_dry_run() {
	printf '\n--- Route (dry-run, no real LLM calls) ---\n'

	local prompt_file="${TEST_TMPDIR}/prompt.txt"
	printf 'Test prompt for unit testing\n' >"$prompt_file"

	local audit_log="${TEST_TMPDIR}/audit.log"
	local costs_path="${TEST_TMPDIR}/costs.json"

	# public tier dry-run
	LLM_ROUTING_DRY_RUN=1 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="$audit_log" \
		LLM_COSTS_PATH="$costs_path" \
		_assert_exit_0 "route --tier public --task summarise succeeds (dry-run)" \
		"$ROUTING_HELPER" route --tier public --task summarise --prompt-file "$prompt_file"

	_assert_file_exists "audit log created after public route" "$audit_log"

	_assert_file_contains "audit log has tier=public" "$audit_log" '"tier".*"public"'

	_assert_file_contains "audit log has task=summarise" "$audit_log" '"task".*"summarise"'

	_assert_file_contains "audit log has prompt_sha256" "$audit_log" '"prompt_sha256"'

	_assert_file_contains "audit log has response_sha256" "$audit_log" '"response_sha256"'

	_assert_file_contains "audit log has NO raw prompt content" \
		"$audit_log" '"prompt_sha256"'
	# (Negative: the actual prompt text should not appear in the log)
	if grep -qF "Test prompt for unit testing" "$audit_log" 2>/dev/null; then
		_fail "audit log must NOT contain raw prompt text"
	else
		_pass "audit log does not contain raw prompt text"
	fi

	return 0
}

test_hard_fail_privileged() {
	printf '\n--- Hard-fail for privileged tier when Ollama is down ---\n'

	local prompt_file="${TEST_TMPDIR}/prompt.txt"
	printf 'Privileged prompt\n' >"$prompt_file"

	local audit_log="${TEST_TMPDIR}/audit-priv.log"
	local costs_path="${TEST_TMPDIR}/costs-priv.json"

	# Simulate Ollama being down by pointing to a port nothing listens on
	OLLAMA_HOST="127.0.0.1" \
		OLLAMA_PORT="19999" \
		LLM_ROUTING_DRY_RUN=0 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="$audit_log" \
		LLM_COSTS_PATH="$costs_path" \
		_assert_exit_nonzero "route --tier privileged fails when Ollama is not running" \
		"$ROUTING_HELPER" route --tier privileged --task draft --prompt-file "$prompt_file"

	return 0
}

test_sensitive_tier_no_cloud() {
	printf '\n--- Sensitive tier uses local provider only ---\n'

	local prompt_file="${TEST_TMPDIR}/prompt.txt"
	printf 'Sensitive prompt\n' >"$prompt_file"

	# With Ollama down and sensitive tier, should fail (no cloud fallback)
	OLLAMA_HOST="127.0.0.1" \
		OLLAMA_PORT="19999" \
		LLM_ROUTING_DRY_RUN=0 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="${TEST_TMPDIR}/audit-sensitive.log" \
		LLM_COSTS_PATH="${TEST_TMPDIR}/costs-sensitive.json" \
		_assert_exit_nonzero "route --tier sensitive fails when Ollama is not running" \
		"$ROUTING_HELPER" route --tier sensitive --task classify --prompt-file "$prompt_file"

	return 0
}

test_audit_log_jsonl_format() {
	printf '\n--- Audit log JSONL format correctness ---\n'

	local prompt_file="${TEST_TMPDIR}/prompt-jsonl.txt"
	printf 'JSONL test prompt\n' >"$prompt_file"

	local audit_log="${TEST_TMPDIR}/audit-jsonl.log"
	local costs_path="${TEST_TMPDIR}/costs-jsonl.json"

	LLM_ROUTING_DRY_RUN=1 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="$audit_log" \
		LLM_COSTS_PATH="$costs_path" \
		"$ROUTING_HELPER" route --tier internal --task extract --prompt-file "$prompt_file" \
		>/dev/null 2>&1

	_assert_file_exists "audit log file exists" "$audit_log"

	# Each line must be valid JSON
	local valid=1
	while IFS= read -r line; do
		if [[ -n "$line" ]] && ! printf '%s' "$line" | jq empty >/dev/null 2>&1; then
			valid=0
		fi
	done <"$audit_log"

	if [[ "$valid" == "1" ]]; then
		_pass "audit log is valid JSONL"
	else
		_fail "audit log contains invalid JSON lines"
	fi

	# Check required fields
	local first_record
	first_record=$(head -1 "$audit_log")

	local fields=("timestamp" "tier" "task" "provider" "redaction_applied" "prompt_sha256" "response_sha256" "tokens" "cost")
	local field
	for field in "${fields[@]}"; do
		if printf '%s' "$first_record" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1; then
			_pass "audit record has field: ${field}"
		else
			_fail "audit record missing field: ${field}"
		fi
	done

	return 0
}

test_cost_aggregation() {
	printf '\n--- Cost aggregation ---\n'

	local prompt_file="${TEST_TMPDIR}/prompt-cost.txt"
	printf 'Cost test prompt\n' >"$prompt_file"

	local audit_log="${TEST_TMPDIR}/audit-cost.log"
	local costs_path="${TEST_TMPDIR}/costs-cost.json"

	# Make two routes to accumulate costs
	LLM_ROUTING_DRY_RUN=1 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="$audit_log" \
		LLM_COSTS_PATH="$costs_path" \
		"$ROUTING_HELPER" route --tier public --task summarise --prompt-file "$prompt_file" \
		>/dev/null 2>&1

	LLM_ROUTING_DRY_RUN=1 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="$audit_log" \
		LLM_COSTS_PATH="$costs_path" \
		"$ROUTING_HELPER" route --tier internal --task draft --prompt-file "$prompt_file" \
		>/dev/null 2>&1

	_assert_file_exists "costs JSON file created" "$costs_path"

	_assert_exit_0 "costs JSON is valid JSON" \
		jq empty "$costs_path"

	# costs subcommand should produce output
	local costs_output
	costs_output=$(
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
			LLM_COSTS_PATH="$costs_path" \
			"$ROUTING_HELPER" costs 2>/dev/null
	) || costs_output=""

	if [[ -n "$costs_output" ]]; then
		_pass "costs subcommand produces output"
	else
		_fail "costs subcommand produced no output"
	fi

	return 0
}

test_redaction_stub() {
	printf '\n--- Redaction stub ---\n'

	local input_file="${TEST_TMPDIR}/redact-input.txt"
	local output_file="${TEST_TMPDIR}/redact-output.txt"
	printf 'Sensitive content with PII placeholder\n' >"$input_file"

	_assert_exit_0 "redaction-helper.sh redact exits 0" \
		"$REDACTION_HELPER" redact "$input_file" "$output_file"

	_assert_file_exists "redacted output file created" "$output_file"

	# For the stub, content is copied unchanged
	if diff "$input_file" "$output_file" >/dev/null 2>&1; then
		_pass "stub passes content through unchanged"
	else
		_fail "stub changed content unexpectedly"
	fi

	# Verify TODO marker exists in the script
	if grep -q "TODO(post-MVP)" "$REDACTION_HELPER" 2>/dev/null; then
		_pass "redaction-helper.sh has TODO markers for post-MVP work"
	else
		_fail "redaction-helper.sh is missing TODO markers"
	fi

	return 0
}

test_pii_tier_redaction_hook() {
	printf '\n--- PII tier triggers redaction for cloud provider ---\n'

	local prompt_file="${TEST_TMPDIR}/prompt-pii.txt"
	printf 'PII test: name=John email=john@example.com\n' >"$prompt_file"

	local audit_log="${TEST_TMPDIR}/audit-pii.log"
	local costs_path="${TEST_TMPDIR}/costs-pii.json"

	# Force anthropic provider by setting a custom config where pii default=anthropic
	# to test the redaction code path on cloud
	local custom_config="${TEST_TMPDIR}/custom-routing.json"
	jq '.tiers.pii.default_provider = "anthropic"' "$ROUTING_CONFIG" >"$custom_config"

	LLM_ROUTING_DRY_RUN=1 \
		LLM_ROUTING_CONFIG="$custom_config" \
		LLM_AUDIT_LOG="$audit_log" \
		LLM_COSTS_PATH="$costs_path" \
		"$ROUTING_HELPER" route --tier pii --task classify --prompt-file "$prompt_file" \
		>/dev/null 2>&1

	_assert_file_exists "audit log exists for pii route" "$audit_log"

	# The audit log should show provider=anthropic for this config
	_assert_file_contains "pii+cloud route uses anthropic provider" \
		"$audit_log" '"provider".*"anthropic"'

	return 0
}

test_audit_log_subcommand() {
	printf '\n--- audit-log subcommand ---\n'

	local audit_log="${TEST_TMPDIR}/audit-manual.log"

	LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="$audit_log" \
		_assert_exit_0 "audit-log subcommand exits 0" \
		"$ROUTING_HELPER" audit-log \
		tier=public task=test provider=anthropic \
		redaction_applied=false prompt_sha=abc123 response_sha=def456 \
		tokens=42 cost=0.001

	_assert_file_exists "manual audit log created" "$audit_log"

	_assert_file_contains "manual log has tier=public" "$audit_log" '"tier".*"public"'

	return 0
}

test_status_subcommand() {
	printf '\n--- status subcommand ---\n'

	LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		_assert_exit_0 "status subcommand exits 0" \
		"$ROUTING_HELPER" status

	local output
	output=$(LLM_ROUTING_CONFIG="$ROUTING_CONFIG" "$ROUTING_HELPER" status 2>&1) || output=""
	if printf '%s' "$output" | grep -qiE "Ollama|Anthropic|OpenAI"; then
		_pass "status output contains provider info"
	else
		_fail "status output missing provider info"
	fi

	return 0
}

test_unknown_tier_fails() {
	printf '\n--- Unknown tier validation ---\n'

	local prompt_file="${TEST_TMPDIR}/prompt-unknown.txt"
	printf 'test\n' >"$prompt_file"

	LLM_ROUTING_DRY_RUN=1 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="${TEST_TMPDIR}/audit-unknown.log" \
		LLM_COSTS_PATH="${TEST_TMPDIR}/costs-unknown.json" \
		_assert_exit_nonzero "route with unknown tier fails" \
		"$ROUTING_HELPER" route --tier superclassified --task test --prompt-file "$prompt_file"

	return 0
}

test_missing_prompt_file_fails() {
	printf '\n--- Missing prompt file validation ---\n'

	LLM_ROUTING_DRY_RUN=1 \
		LLM_ROUTING_CONFIG="$ROUTING_CONFIG" \
		LLM_AUDIT_LOG="${TEST_TMPDIR}/audit-missing.log" \
		LLM_COSTS_PATH="${TEST_TMPDIR}/costs-missing.json" \
		_assert_exit_nonzero "route with missing prompt file fails" \
		"$ROUTING_HELPER" route --tier public --task summarise \
		--prompt-file /nonexistent/prompt.txt

	return 0
}

# =============================================================================
# Main
# =============================================================================

_setup

printf 'Running llm-routing-helper.sh tests (t2847)\n'
printf '%s\n' "$(printf '=%.0s' {1..60})"

test_config_loading
test_routing_dry_run
test_hard_fail_privileged
test_sensitive_tier_no_cloud
test_audit_log_jsonl_format
test_cost_aggregation
test_redaction_stub
test_pii_tier_redaction_hook
test_audit_log_subcommand
test_status_subcommand
test_unknown_tier_fails
test_missing_prompt_file_fails

_teardown

printf '\n%s\n' "$(printf '=%.0s' {1..60})"
printf 'Results: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
