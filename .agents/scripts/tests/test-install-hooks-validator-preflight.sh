#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-install-hooks-validator-preflight.sh — t2226 regression test.
#
# Validates the pre-install gates in install-hooks-helper.sh:
#   1. _dry_run_validators function exists.
#   2. Happy path: validators pass → install proceeds (function returns 0).
#   3. Failure path: a broken validator → install aborts (function returns 1).
#   4. Force-install path: --force-install bypasses failure (returns 0 with warning).
#   5. install_hook accepts --force-install flag.
#   6. Validator enumeration finds validate_* functions from pre-commit-hook.sh.
#
# Full-install tests avoid real installation. The scoped CLI cases install only
# into disposable repositories with an isolated HOME, never the user's hooks.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

# --- Test 1: _dry_run_validators function exists ---
test_function_exists() {
	if grep -q '^_dry_run_validators()' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh"; then
		print_result "_dry_run_validators() function exists" 0
	else
		print_result "_dry_run_validators() function exists" 1 "not found in install-hooks-helper.sh"
	fi
	return 0
}

# --- Test 2: install_hook accepts --force-install ---
test_force_install_flag() {
	if grep -q '\-\-force-install' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh"; then
		print_result "install_hook accepts --force-install" 0
	else
		print_result "install_hook accepts --force-install" 1 "flag not found"
	fi
	return 0
}

# --- Test 3: Validator enumeration finds functions ---
test_validator_enumeration() {
	local pch="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"
	if [[ ! -f "$pch" ]]; then
		print_result "validator enumeration" 1 "pre-commit-hook.sh not found"
		return 0
	fi
	local count
	count=$(grep -oE 'validate_[a-z_]+\(\)' "$pch" | sed 's/()//' | sort -u | wc -l | tr -d ' ')
	if [[ "$count" -gt 0 ]]; then
		print_result "validator enumeration finds $count validators" 0
	else
		print_result "validator enumeration finds validators" 1 "found 0"
	fi
	return 0
}

# --- Test 4: _dry_run_validators is called in install flow ---
test_dry_run_called_in_install() {
	if grep -q '_dry_run_validators.*force_install' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh"; then
		print_result "_dry_run_validators called in install flow" 0
	else
		print_result "_dry_run_validators called in install flow" 1 "call not found in install_hook"
	fi
	return 0
}

# --- Helper: run _dry_run_validators with a mock pre-commit-hook.sh ---
# Creates a temp mock, sources install-hooks-helper.sh functions, overrides
# _find_pre_commit_hook AFTER sourcing (so the override sticks), then calls
# _dry_run_validators.
_run_dry_run_test() {
	local mock_content="$1"
	local force_flag="$2"

	local test_tmpdir
	test_tmpdir=$(mktemp -d)

	cat >"$test_tmpdir/pre-commit-hook.sh" <<MOCK_EOF
$mock_content
MOCK_EOF

	# Write a test harness script that sources the helper and runs the function
	cat >"$test_tmpdir/harness.sh" <<HARNESS_EOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$TEST_SCRIPTS_DIR"
# shellcheck source=../shared-constants.sh disable=SC1091
[[ -f "\${SCRIPT_DIR}/shared-constants.sh" ]] && source "\${SCRIPT_DIR}/shared-constants.sh"

# Source functions from install-hooks-helper.sh, skipping set -euo and main block
eval "\$(sed '/^set -euo pipefail\$/d; /^# Main\$/,\$ d' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh")"

# Override _find_pre_commit_hook AFTER sourcing (so our mock wins)
_find_pre_commit_hook() {
	echo "$test_tmpdir/pre-commit-hook.sh"
	return 0
}

_dry_run_validators "unused" "$force_flag"
HARNESS_EOF

	local rc=0
	bash "$test_tmpdir/harness.sh" >/dev/null 2>&1 || rc=$?
	rm -rf "$test_tmpdir"
	return $rc
}

# --- Test 5: Dry-run passes with valid validators (happy path) ---
test_dry_run_happy_path() {
	local mock_body
	mock_body='#!/usr/bin/env bash
validate_test_pass() {
	return 0
}'

	local rc=0
	_run_dry_run_test "$mock_body" "false" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "dry-run happy path (passing validator)" 0
	else
		print_result "dry-run happy path (passing validator)" 1 "exit=$rc"
	fi
	return 0
}

# --- Test 6: Dry-run fails with broken validator ---
test_dry_run_failure_path() {
	local mock_body
	mock_body='#!/usr/bin/env bash
validate_test_fail() {
	return 1
}'

	local rc=0
	_run_dry_run_test "$mock_body" "false" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		print_result "dry-run failure path (broken validator aborts)" 0
	else
		print_result "dry-run failure path (broken validator aborts)" 1 "expected non-zero exit"
	fi
	return 0
}

# --- Test 7: --force-install bypasses failure ---
test_force_install_bypass() {
	local mock_body
	mock_body='#!/usr/bin/env bash
validate_test_fail() {
	return 1
}'

	local rc=0
	_run_dry_run_test "$mock_body" "true" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "force-install bypasses broken validator" 0
	else
		print_result "force-install bypasses broken validator" 1 "exit=$rc"
	fi
	return 0
}

# --- Test 8: help text includes --force-install ---
test_help_text() {
	local output
	output=$(bash "$TEST_SCRIPTS_DIR/install-hooks-helper.sh" help 2>&1)
	if echo "$output" | grep -q '\-\-force-install'; then
		print_result "help text mentions --force-install" 0
	else
		print_result "help text mentions --force-install" 1 "not in help output"
	fi
	return 0
}

_run_runtime_dependency_test() {
	local mode="$1"
	local test_tmpdir
	test_tmpdir=$(mktemp -d)
	local test_home="$test_tmpdir/home"
	mkdir -p "$test_home/.aidevops/agents/scripts"

	if [[ "$mode" == "healthy" ]]; then
		cat >"$test_home/.aidevops/agents/scripts/command-policy-helper.py" <<'PYEOF'
#!/usr/bin/env python3
raise SystemExit(0)
PYEOF
		cat >"$test_home/.aidevops/agents/scripts/canonical-write-policy-helper.py" <<'PYEOF'
#!/usr/bin/env python3
raise SystemExit(0)
PYEOF
	fi

	cat >"$test_tmpdir/harness.sh" <<HARNESS_EOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$TEST_SCRIPTS_DIR"
source "\${SCRIPT_DIR}/shared-constants.sh"
eval "\$(sed '/^set -euo pipefail\$/d; /^# Main\$/,\$ d' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh")"
_check_runtime_policy_dependencies
HARNESS_EOF

	local rc=0
	local output=""
	output=$(HOME="$test_home" bash "$test_tmpdir/harness.sh" 2>&1) || rc=$?
	rm -rf "$test_tmpdir"
	if [[ "$rc" -ne 0 && "$mode" == "healthy" ]]; then
		printf '%s\n' "$output" >&2
	fi
	return "$rc"
}

test_runtime_dependency_preflight() {
	local rc=0
	_run_runtime_dependency_test "missing" || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "missing deployed policy graph blocks hook installation" 0
	else
		print_result "missing deployed policy graph blocks hook installation" 1 "expected non-zero exit"
	fi

	rc=0
	_run_runtime_dependency_test "healthy" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "healthy deployed policy graph passes hook preflight" 0
	else
		print_result "healthy deployed policy graph passes hook preflight" 1 "exit=$rc"
	fi
	return 0
}

test_installed_hook_probe() {
	local test_tmpdir
	test_tmpdir=$(mktemp -d)
	local test_home="$test_tmpdir/home"
	local installed_hook="$test_home/.aidevops/hooks/git_safety_guard.py"
	mkdir -p "$(dirname "$installed_hook")"
	cp "$TEST_SCRIPTS_DIR/../hooks/git_safety_guard.py" "$installed_hook"
	chmod +x "$installed_hook"
	cat >"$test_tmpdir/harness.sh" <<HARNESS_EOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$TEST_SCRIPTS_DIR"
source "\${SCRIPT_DIR}/shared-constants.sh"
eval "\$(sed '/^set -euo pipefail\$/d; /^# Main\$/,\$ d' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh")"
_probe_hook_runtime "$installed_hook"
HARNESS_EOF

	local missing_rc=0
	local output=""
	output=$(HOME="$test_home" bash "$test_tmpdir/harness.sh" 2>&1) || missing_rc=$?
	if [[ "$missing_rc" -ne 0 ]]; then
		print_result "installed hook probe detects policy.helper-unavailable" 0
	else
		print_result "installed hook probe detects policy.helper-unavailable" 1 "expected non-zero exit"
	fi

	ln -s "$TEST_SCRIPTS_DIR/.." "$test_home/.aidevops/agents"
	local healthy_rc=0
	output=$(HOME="$test_home" bash "$test_tmpdir/harness.sh" 2>&1) || healthy_rc=$?
	if [[ "$healthy_rc" -eq 0 ]]; then
		print_result "installed hook probe accepts complete deployed policy graph" 0
	else
		print_result "installed hook probe accepts complete deployed policy graph" 1 "exit=$healthy_rc output=$output"
	fi

	rm -rf "$test_tmpdir"
	return 0
}

_prepare_pre_commit_fixture() {
	local fixture="$1"
	mkdir -p "$fixture/home/.aidevops/agents/scripts" "$fixture/home/.aidevops/hooks" \
		"$fixture/home/.claude" "$fixture/scripts" "$fixture/repo" || return 1
	cp "$TEST_SCRIPTS_DIR/install-hooks-helper.sh" "$fixture/scripts/" || return 1
	# Load the real constants with their complete sibling dependency graph.
	printf 'source %q\n' "$TEST_SCRIPTS_DIR/shared-constants.sh" >"$fixture/scripts/shared-constants.sh"
	printf '%s\n' 'user settings sentinel' >"$fixture/home/.claude/settings.json"
	printf '%s\n' 'user hook sentinel' >"$fixture/home/.aidevops/hooks/existing"
	cat >"$fixture/home/.aidevops/agents/scripts/pre-commit-hook.sh" <<'HOOK'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/probe-dependency.sh"
validate_probe() {
	return "$PROBE_RESULT"
}
main() {
	validate_probe || return 1
	return "${RUNTIME_RESULT:-0}"
}
main "$@"
HOOK
	printf '%s\n' 'PROBE_RESULT=0' >"$fixture/home/.aidevops/agents/scripts/probe-dependency.sh"
	chmod +x "$fixture/home/.aidevops/agents/scripts/pre-commit-hook.sh"
	# A different adjacent checkout must not be mistaken for the runtime hook.
	printf '%s\n' 'validate_wrong_checkout() { return 1; }' >"$fixture/scripts/pre-commit-hook.sh"
	git -C "$fixture/repo" init -q || return 1
	printf '%s\n' 'fixture' >"$fixture/repo/README.md"
	git -C "$fixture/repo" add README.md || return 1
	git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
		-c commit.gpgSign=false commit -qm fixture || return 1
	printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture/repo/.git/hooks/pre-push"
	cp "$fixture/repo/.git/hooks/pre-push" "$fixture/pre-push-before"
	return 0
}

test_pre_commit_only_case() {
	local mode="$1"
	local fixture
	fixture=$(mktemp -d) || return 1
	# Isolate Git configuration and every potential user-level installation target.
	local HOME="$fixture/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
	export HOME GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
	if ! _prepare_pre_commit_fixture "$fixture"; then
		print_result "scoped CLI fixture: $mode" 1
		rm -rf "$fixture"
		return 0
	fi
	local cwd="$fixture/repo" hook="$fixture/repo/.git/hooks/pre-commit"
	local runtime_dir="$HOME/.aidevops/agents/scripts"
	local expected=0 reason="" args=(install-pre-commit)
	case "$mode" in
	linked)
		git -C "$cwd" worktree add -qb fixture-linked "$fixture/linked" || return 1
		cwd="$fixture/linked"
		;;
	existing | managed)
		printf '%s\n' '#!/bin/sh' 'exit 7' >"$hook"
		if [[ "$mode" == "managed" ]]; then
			printf '%s\n' '# aidevops-pre-commit-hook' '# preserve appended custom checks' >>"$hook"
		else
			expected=1
			reason="Existing pre-commit hook requires manual review"
		fi
		chmod +x "$hook"
		cp "$hook" "$fixture/pre-commit-before"
		;;
	symlink)
		ln -s "$fixture/nonexistent" "$hook"
		expected=1
		reason="symlinked pre-commit"
		;;
	hooks-path)
		git -C "$cwd" config core.hooksPath "$fixture/custom-hooks"
		expected=1
		reason="core.hooksPath is configured"
		;;
	missing-runtime)
		rm "$runtime_dir/pre-commit-hook.sh"
		expected=1
		reason="No executable repository or deployed pre-commit validator"
		;;
	bad-validator)
		printf '%s\n' 'PROBE_RESULT=1' >"$runtime_dir/probe-dependency.sh"
		expected=1
		reason="Validator preflight failed"
		;;
	bad-runtime)
		printf '%s\n' 'RUNTIME_RESULT=1' >>"$runtime_dir/probe-dependency.sh"
		expected=1
		reason="Pre-commit runtime check failed"
		;;
	local-runtime)
		mkdir -p "$cwd/.agents/scripts"
		cp "$runtime_dir/"*.sh "$cwd/.agents/scripts/"
		printf '%s\n' 'PROBE_RESULT=1' >"$runtime_dir/probe-dependency.sh"
		;;
	outside)
		cwd="$fixture"
		expected=1
		reason="requires a Git working tree"
		;;
	bare)
		git init -q --bare "$fixture/bare" || return 1
		cwd="$fixture/bare"
		expected=1
		reason="requires a Git working tree"
		;;
	force | unknown)
		args+=("--$mode-install")
		expected=1
		reason="accepts no options"
		;;
	happy) ;;
	*) return 1 ;;
	esac
	cp -R "$HOME" "$fixture/home-before"
	local rc=0 output="" result=0
	output=$(cd "$cwd" && bash "$fixture/scripts/install-hooks-helper.sh" "${args[@]}" 2>&1) || rc=$?
	_check_pre_commit_only_result "$mode" "$fixture" "$cwd" "$expected" "$reason" "$output" "$rc" || result=$?
	print_result "install-pre-commit: $mode; preserves pre-push and user settings" "$result" "$output"
	rm -rf "$fixture"
	return 0
}

_check_pre_commit_only_result() {
	local mode="$1" fixture="$2" cwd="$3" expected="$4" reason="$5" output="$6" rc="$7"
	local hook="$fixture/repo/.git/hooks/pre-commit" result=0
	if [[ "$expected" -eq 0 ]]; then
		[[ "$rc" -eq 0 && -x "$hook" ]] || result=1
		if [[ "$mode" != "managed" && "$rc" -eq 0 && -x "$hook" ]]; then
			# Exercise Git's installed entrypoint, then verify a repeat is a no-op.
			git -C "$cwd" hook run pre-commit >/dev/null 2>&1 || result=1
			cp "$hook" "$fixture/pre-commit-before"
			(cd "$cwd" && bash "$fixture/scripts/install-hooks-helper.sh" install-pre-commit) >/dev/null 2>&1 || result=1
		fi
	else
		[[ "$rc" -ne 0 && "$output" == *"$reason"* ]] || result=1
		if [[ "$mode" == "symlink" ]]; then
			[[ -L "$hook" && ! -e "$fixture/nonexistent" ]] || result=1
		elif [[ "$mode" != "existing" ]]; then
			[[ ! -e "$hook" ]] || result=1
		fi
	fi
	if [[ -f "$fixture/pre-commit-before" ]]; then
		cmp -s "$fixture/pre-commit-before" "$hook" || result=1
	fi
	cmp -s "$fixture/pre-push-before" "$fixture/repo/.git/hooks/pre-push" || result=1
	diff -rq "$fixture/home-before" "$fixture/home" >/dev/null || result=1
	return "$result"
}

# --- Run all tests ---
main() {
	echo "=== install-hooks-helper.sh validator preflight tests (t2226) ==="
	echo ""

	test_function_exists
	test_force_install_flag
	test_validator_enumeration
	test_dry_run_called_in_install
	test_dry_run_happy_path
	test_dry_run_failure_path
	test_force_install_bypass
	test_help_text
	test_runtime_dependency_preflight
	test_installed_hook_probe
	local mode
	for mode in happy linked managed existing symlink hooks-path missing-runtime bad-validator bad-runtime local-runtime outside bare force unknown; do
		test_pre_commit_only_case "$mode" || return 1
	done

	echo ""
	echo "=== Results: $TESTS_RUN tests, $TESTS_FAILED failures ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
