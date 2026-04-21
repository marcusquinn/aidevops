#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-setup-tools-zsh-compat.sh — t2719 regression guard (GH#20393).
#
# Asserts that _setup_pim_tools_linux_check and _setup_pim_tools_linux_install
# do NOT emit `local:2: bad option: -n` under zsh and that the module-global
# pattern works correctly (no nameref required).
#
# Background
# ----------
# setup/_tools.sh is sourced by setup.sh at line 83. setup.sh does NOT
# source shared-constants.sh, so the re-exec guard that would normally
# re-launch scripts under Homebrew bash 4+ cannot fire when setup.sh is
# run under /bin/bash 3.2 (macOS default before Homebrew install) or when
# zsh is the host shell.
#
# The original implementation used `local -n` (bash 4.3+ namerefs) in two
# functions. Namerefs are a bash-only feature — zsh's `local` does not
# accept `-n` and emits `local:N: bad option: -n`. Under bash 3.2, `local -n`
# is also unsupported.
#
# The fix (t2719) replaces namerefs with a module-level global
# _SETUP_TOOLS_LINUX_MISSING, mirroring the pattern already used in
# shared-gh-wrappers.sh (t2688 / GH#20300).
#
# Skip behaviour
# --------------
# If zsh is not installed, the test emits a SKIP notice and exits 0.
# If print_success/print_info/print_warning are unavailable (stub functions
# are injected below for isolated testing).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_YELLOW=$'\033[1;33m'
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

print_skip() {
	local name="$1" reason="$2"
	printf '%sSKIP%s %s (%s)\n' "$TEST_YELLOW" "$TEST_RESET" "$name" "$reason"
	return 0
}

# =============================================================================
# Environment check
# =============================================================================
if ! command -v zsh >/dev/null 2>&1; then
	print_skip "t2719 zsh-compat smoke test" "zsh not installed"
	printf '\n%sTests run: 0, failed: 0 (skipped — zsh unavailable)%s\n' \
		"$TEST_YELLOW" "$TEST_RESET"
	exit 0
fi

TOOLS_FILE="${TEST_SCRIPTS_DIR}/setup/_tools.sh"
if [[ ! -f "$TOOLS_FILE" ]]; then
	print_result "t2719: setup/_tools.sh exists" 1 "(missing: $TOOLS_FILE)"
	printf '\n%sTests run: %d, failed: %d%s\n' \
		"$TEST_RED" "$TESTS_RUN" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi

# =============================================================================
# Helper: extract a single function body via awk
# =============================================================================
extract_function() {
	local fname="$1" file="$2"
	awk -v fn="$fname" '
		$0 ~ "^" fn "\\(\\) \\{" { in_fn=1 }
		in_fn { print }
		in_fn && /^}$/ { in_fn=0 }
	' "$file"
	return 0
}

# =============================================================================
# Scenario 1 — functions do NOT emit `local -n` error under zsh
# =============================================================================
#
# Extract the three relevant function bodies: the module-global declaration
# block, _setup_pim_tools_linux_check, and _setup_pim_tools_linux_install.
# Inject stub print_* helpers so the functions can be evaluated in isolation.
# Stub out command -v to return 1 (no tools installed) so the check function
# populates _SETUP_TOOLS_LINUX_MISSING with all four packages.

TMPFILE=$(mktemp "${TMPDIR:-/tmp}/t2719-zsh-snippet.XXXXXX.sh")
trap 'rm -f "$TMPFILE"' EXIT

{
	# Stub print helpers (zsh-compatible: no process substitution, no bash-ism)
	printf '%s\n' 'print_success() { :; }'
	printf '%s\n' 'print_info() { :; }'
	printf '%s\n' 'print_warning() { :; }'
	printf '\n'
	# Stub command -v to return 1 (simulate "no tools installed")
	printf '%s\n' 'command() { return 1; }'
	printf '\n'
	# Module global declaration from the file
	printf '%s\n' '_SETUP_TOOLS_LINUX_MISSING=()'
	printf '\n'
	extract_function _setup_pim_tools_linux_check "$TOOLS_FILE"
	printf '\n'
	extract_function _setup_pim_tools_linux_install "$TOOLS_FILE"
	printf '\n'
	# Invoke check and capture the resulting global
	# shellcheck disable=SC2016 # Intentional: emit literal expressions for zsh
	printf '%s\n' '_setup_pim_tools_linux_check 2>&1'
	# shellcheck disable=SC2016 # Intentional
	printf '%s\n' 'echo "missing_count=${#_SETUP_TOOLS_LINUX_MISSING[@]}"'
	# Print all items space-separated; avoids 0-vs-1 index difference between bash/zsh.
	# shellcheck disable=SC2016 # Intentional
	printf '%s\n' 'echo "missing_items=${_SETUP_TOOLS_LINUX_MISSING[*]}"'
} >"$TMPFILE"

zsh_output=$(zsh "$TMPFILE" 2>&1)

# Assertion 1a: no `local -n` error emitted
msg_1a="1a: zsh invocation does not emit 'bad option: -n'"
if [[ "$zsh_output" == *"bad option: -n"* ]]; then
	print_result "$msg_1a" 1 "(zsh output: ${zsh_output})"
else
	print_result "$msg_1a" 0
fi

# Assertion 1b: _SETUP_TOOLS_LINUX_MISSING is populated (4 tools expected when none installed)
msg_1b="1b: _SETUP_TOOLS_LINUX_MISSING has 4 entries when no PIM tools installed"
if echo "$zsh_output" | grep -q "missing_count=4"; then
	print_result "$msg_1b" 0
else
	print_result "$msg_1b" 1 "(expected missing_count=4, got: '${zsh_output}')"
fi

# Assertion 1c: 'todoman' appears in the missing items (order is deterministic;
# index 0 in bash == index 1 in zsh, so we check for membership not position).
msg_1c="1c: 'todoman' appears in _SETUP_TOOLS_LINUX_MISSING items"
if echo "$zsh_output" | grep -q "todoman"; then
	print_result "$msg_1c" 0
else
	print_result "$msg_1c" 1 "(expected todoman in items, got: '${zsh_output}')"
fi

# =============================================================================
# Scenario 2 — source guard: no `local -n` in the two check/install functions
# =============================================================================

msg_2="2: no 'local -n' in _setup_pim_tools_linux_check or _setup_pim_tools_linux_install"
if awk '
	/^_setup_pim_tools_linux_(check|install)\(\) \{/ { in_fn=1 }
	in_fn && /[[:space:]]local -n / { found=1 }
	in_fn && /^}$/ { in_fn=0 }
	END { exit (found ? 1 : 0) }
' "$TOOLS_FILE"; then
	print_result "$msg_2" 0
else
	print_result "$msg_2" 1 "(found 'local -n' — fix regressed)"
fi

# =============================================================================
# Scenario 3 — module global _SETUP_TOOLS_LINUX_MISSING declared at file scope
# =============================================================================

msg_3="3: _SETUP_TOOLS_LINUX_MISSING declared at module scope"
if grep -q "^_SETUP_TOOLS_LINUX_MISSING=()" "$TOOLS_FILE"; then
	print_result "$msg_3" 0
else
	print_result "$msg_3" 1 "(not found in $TOOLS_FILE)"
fi

# =============================================================================
# Scenario 4 — setup_pim_tools does not pass array name as argument
# =============================================================================
#
# After the t2719 transformation, setup_pim_tools should call the helpers
# without arguments (no `local missing=()` + `_setup_pim_tools_linux_check missing`).

msg_4="4: setup_pim_tools does not pass 'missing' as arg to check/install functions"
if awk '
	/^setup_pim_tools\(\) \{/ { in_fn=1 }
	in_fn && /_setup_pim_tools_linux_(check|install) missing/ { found=1 }
	in_fn && /^}$/ { in_fn=0 }
	END { exit (found ? 1 : 0) }
' "$TOOLS_FILE"; then
	print_result "$msg_4" 0
else
	print_result "$msg_4" 1 "(caller still passes 'missing' — update not applied)"
fi

# =============================================================================
# Summary
# =============================================================================
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\n%sTests run: %d, failed: 0%s\n' \
		"$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '\n%sTests run: %d, failed: %d%s\n' \
		"$TEST_RED" "$TESTS_RUN" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi
