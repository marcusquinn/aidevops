#!/usr/bin/env bash
# =============================================================================
# Tests for gh-signature-helper.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../gh-signature-helper.sh"

PASS=0
FAIL=0

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected NOT to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== gh-signature-helper.sh tests ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: generate with explicit CLI, model, tokens
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: generate with all explicit fields"
result=$("$HELPER" generate --cli "OpenCode CLI" --cli-version "1.3.3" --model "anthropic/claude-opus-4-6" --tokens 1234)
assert_contains "contains CLI link" "[OpenCode CLI](https://opencode.ai) v1.3.3" "$result"
assert_contains "contains aidevops link" "[aidevops.sh](https://aidevops.sh)" "$result"
assert_contains "contains model" "anthropic/claude-opus-4-6" "$result"
assert_contains "contains formatted tokens" "1,234 tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: generate with explicit --tokens 0 (should omit tokens)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: explicit --tokens 0 omits tokens"
result=$("$HELPER" generate --cli "Claude Code" --cli-version "2.0.1" --model "anthropic/claude-sonnet-4-6" --tokens 0)
assert_contains "contains Claude Code link" "[Claude Code](https://claude.ai/code) v2.0.1" "$result"
assert_not_contains "no tokens field" "tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: generate with zero tokens (should omit)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: zero tokens omitted"
result=$("$HELPER" generate --cli "OpenCode CLI" --model "anthropic/claude-opus-4-6" --tokens 0)
assert_not_contains "zero tokens omitted" "tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: generate with no model (should omit model)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: no model"
result=$("$HELPER" generate --cli "Cursor")
assert_contains "contains Cursor link" "[Cursor](https://cursor.com)" "$result"
assert_contains "contains aidevops" "aidevops.sh" "$result"
# Should only have CLI and aidevops, no trailing comma-model
assert_not_contains "no model field" "anthropic" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: footer command includes --- separator
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: footer includes --- separator"
result=$("$HELPER" footer --cli "OpenCode CLI" --cli-version "1.0.0" --model "anthropic/claude-sonnet-4-6" --tokens 5000)
assert_contains "contains ---" "---" "$result"
assert_contains "contains signature" "[OpenCode CLI](https://opencode.ai) v1.0.0" "$result"
assert_contains "contains tokens" "5,000 tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: comma formatting for various numbers
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: comma formatting"
result=$("$HELPER" generate --cli "Test" --model "m" --tokens 999)
assert_contains "3-digit no comma" "999 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1000)
assert_contains "4-digit with comma" "1,000 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 45000)
assert_contains "5-digit with comma" "45,000 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1234567)
assert_contains "7-digit with commas" "1,234,567 tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: CLI URL mapping for known runtimes
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: CLI URL mapping"
result=$("$HELPER" generate --cli "OpenCode CLI" --model "m")
assert_contains "OpenCode URL" "https://opencode.ai" "$result"

result=$("$HELPER" generate --cli "Claude Code" --model "m")
assert_contains "Claude Code URL" "https://claude.ai/code" "$result"

result=$("$HELPER" generate --cli "Cursor" --model "m")
assert_contains "Cursor URL" "https://cursor.com" "$result"

result=$("$HELPER" generate --cli "Aider" --model "m")
assert_contains "Aider URL" "https://aider.chat" "$result"

result=$("$HELPER" generate --cli "Windsurf" --model "m")
assert_contains "Windsurf URL" "https://windsurf.com" "$result"

result=$("$HELPER" generate --cli "Continue" --model "m")
assert_contains "Continue URL" "https://continue.dev" "$result"

result=$("$HELPER" generate --cli "GitHub Copilot" --model "m")
assert_contains "Copilot URL" "https://github.com/features/copilot" "$result"

result=$("$HELPER" generate --cli "Cody" --model "m")
assert_contains "Cody URL" "https://sourcegraph.com/cody" "$result"

result=$("$HELPER" generate --cli "Kilo Code" --model "m")
assert_contains "Kilo Code URL" "https://kilocode.ai" "$result"

result=$("$HELPER" generate --cli "Augment" --model "m")
assert_contains "Augment URL" "https://augmentcode.com" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: unknown CLI gets no link
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: unknown CLI has no link"
result=$("$HELPER" generate --cli "SomeNewTool" --model "m")
assert_contains "CLI name present" "SomeNewTool" "$result"
assert_not_contains "no CLI markdown link" "[SomeNewTool](" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: env var overrides
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 9: environment variable overrides"
result=$(AIDEVOPS_SIG_CLI="EnvCLI" AIDEVOPS_SIG_CLI_VERSION="9.9.9" AIDEVOPS_SIG_MODEL="test/model" AIDEVOPS_SIG_TOKENS="42000" "$HELPER" generate)
assert_contains "env CLI name" "EnvCLI" "$result"
assert_contains "env CLI version" "v9.9.9" "$result"
assert_contains "env model" "test/model" "$result"
assert_contains "env tokens" "42,000 tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: auto-detect tokens from OpenCode session DB (if running in OpenCode)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 10: auto-detect tokens from session DB"
if [[ "${OPENCODE:-}" == "1" ]] && [[ -r "${HOME}/.local/share/opencode/opencode.db" ]]; then
	result=$("$HELPER" generate --cli "OpenCode CLI" --model "anthropic/claude-opus-4-6")
	assert_contains "auto-detected tokens present" "tokens" "$result"
else
	echo "  SKIP: not running in OpenCode (auto-detect test requires OpenCode session DB)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: help command exits cleanly
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 11: help command"
result=$("$HELPER" help 2>&1)
assert_contains "help shows usage" "Usage:" "$result"
assert_contains "help shows examples" "Examples:" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
