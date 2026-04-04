#!/usr/bin/env bash
# test-ollama-helper.sh
#
# Tests for ollama-helper.sh (t1873.7)
# Validates: syntax, shellcheck, help output, subcommand dispatch,
# and graceful failure when Ollama server is not running.
#
# Usage: bash tests/test-ollama-helper.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/ollama-helper.sh"
VERBOSE="${1:-}"

# Portable timeout: gtimeout (macOS homebrew) > timeout (Linux) > none
TIMEOUT_CMD=""
if command -v gtimeout &>/dev/null; then
	TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
	TIMEOUT_CMD="timeout"
fi

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

# ============================================================
# SECTION 1: Basic Validation
# ============================================================
section "Basic Validation"

# File exists
if [[ -f "$HELPER" ]]; then
	pass "ollama-helper.sh exists at expected path"
else
	fail "ollama-helper.sh not found" "Expected: $HELPER"
fi

# Syntax check
if bash -n "$HELPER" 2>/dev/null; then
	pass "bash -n syntax check"
else
	fail "bash -n syntax check" "Script has syntax errors"
fi

# ShellCheck
if command -v shellcheck &>/dev/null; then
	sc_output=$(shellcheck "$HELPER" 2>&1 || true)
	sc_errors=$(printf '%s\n' "$sc_output" | grep -c "^.*error" 2>/dev/null || true)
	if [[ "$sc_errors" -eq 0 ]]; then
		pass "shellcheck (0 errors)"
	else
		fail "shellcheck ($sc_errors errors)" "$(printf '%s\n' "$sc_output" | head -5)"
	fi
else
	skip "shellcheck not installed"
fi

# ============================================================
# SECTION 2: Help Command
# ============================================================
section "Help Command"

help_output=$(run_with_timeout 5 bash "$HELPER" help 2>&1) || true
if [[ -n "$help_output" ]]; then
	pass "help command produces output"
else
	fail "help command produces output" "No output"
fi

# Help mentions all subcommands
for subcmd in status serve stop models pull recommend validate; do
	if printf '%s\n' "$help_output" | grep -q "$subcmd"; then
		pass "help mentions '$subcmd' subcommand"
	else
		fail "help mentions '$subcmd' subcommand"
	fi
done

# Help mentions key options (use -F -- to avoid -- being parsed as grep flag)
for opt in "--num-ctx" "--host" "--port" "--json"; do
	if printf '%s\n' "$help_output" | grep -qF -- "$opt"; then
		pass "help mentions '$opt' option"
	else
		fail "help mentions '$opt' option"
	fi
done

# --help and -h aliases
help_alias_output=$(run_with_timeout 5 bash "$HELPER" --help 2>&1) || true
if [[ -n "$help_alias_output" ]]; then
	pass "--help alias produces output"
else
	fail "--help alias produces output" "No output"
fi

# ============================================================
# SECTION 3: Subcommand Dispatch (no server required)
# ============================================================
section "Subcommand Dispatch"

# Unknown subcommand should exit non-zero
if run_with_timeout 5 bash "$HELPER" nonexistent_subcommand_xyz >/dev/null 2>&1; then
	fail "unknown subcommand returns non-zero exit" "Expected non-zero, got 0"
else
	pass "unknown subcommand returns non-zero exit"
fi

# recommend does not require a running server
recommend_exit=0
recommend_output=$(run_with_timeout 10 bash "$HELPER" recommend 2>&1) || recommend_exit=$?
if [[ "$recommend_exit" -eq 0 && -n "$recommend_output" ]]; then
	pass "recommend subcommand runs without server"
else
	fail "recommend subcommand runs without server" "Exit: $recommend_exit"
fi

# recommend --json produces JSON
recommend_json=$(run_with_timeout 10 bash "$HELPER" recommend --json 2>&1) || true
if printf '%s\n' "$recommend_json" | grep -q '"ram_gb"'; then
	pass "recommend --json produces JSON with ram_gb field"
else
	fail "recommend --json produces JSON with ram_gb field" "Got: $recommend_json"
fi

# ============================================================
# SECTION 4: Graceful Failure When Server Not Running
# ============================================================
section "Graceful Failure (No Server)"

# status should not crash even when server is not running
status_exit=0
status_output=$(run_with_timeout 10 bash "$HELPER" status 2>&1) || status_exit=$?
# Exit 0 (server running) or 1 (not running) are both acceptable
case "$status_exit" in
0) pass "status: server running" ;;
1) pass "status: server not running (graceful failure — expected in CI)" ;;
*) fail "status: unexpected exit code $status_exit (expected 0 or 1)" ;;
esac

# models should fail gracefully when server not running
models_exit=0
run_with_timeout 10 bash "$HELPER" models >/dev/null 2>&1 || models_exit=$?
case "$models_exit" in
0) pass "models: server running, returned model list" ;;
1) pass "models: server not running (graceful failure — expected in CI)" ;;
*) fail "models: unexpected exit code $models_exit (expected 0 or 1)" ;;
esac

# pull without model name should return usage error (not crash)
pull_exit=0
run_with_timeout 5 bash "$HELPER" pull >/dev/null 2>&1 || pull_exit=$?
if [[ "$pull_exit" -ne 0 ]]; then
	pass "pull without model name returns non-zero exit"
else
	fail "pull without model name should return non-zero exit"
fi

# validate without model name should return usage error (not crash)
validate_exit=0
run_with_timeout 5 bash "$HELPER" validate >/dev/null 2>&1 || validate_exit=$?
if [[ "$validate_exit" -ne 0 ]]; then
	pass "validate without model name returns non-zero exit"
else
	fail "validate without model name should return non-zero exit"
fi

# ============================================================
# SECTION 5: Server-Dependent Tests (skipped if not running)
# ============================================================
section "Server-Dependent Tests"

# Detect if Ollama is running
ollama_running=false
if curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
	ollama_running=true
fi

if [[ "$ollama_running" == "true" ]]; then
	# status --json when server is running
	status_json=$(run_with_timeout 10 bash "$HELPER" status --json 2>&1) || true
	if printf '%s\n' "$status_json" | grep -q '"running":true'; then
		pass "status --json: running=true when server is up"
	else
		fail "status --json: expected running=true" "Got: $status_json"
	fi

	# models subcommand
	models_exit2=0
	run_with_timeout 10 bash "$HELPER" models >/dev/null 2>&1 || models_exit2=$?
	if [[ "$models_exit2" -eq 0 ]]; then
		pass "models: returns list when server is running"
	else
		fail "models: unexpected exit $models_exit2 when server is running"
	fi
else
	skip "status --json running=true (Ollama server not running)"
	skip "models list (Ollama server not running)"
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
