#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Verify planning advisories survive legacy metadata and unavailable stdin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--check" ]]; then
	# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
	source "$SCRIPT_DIR/../aidevops-cli/aidevops-repos-lib.sh"
	# shellcheck source=../aidevops-cli/aidevops-update-lib.sh
	source "$SCRIPT_DIR/../aidevops-cli/aidevops-update-lib.sh"
	get_registered_repos() { printf '%s\n' "$TEST_PROJECT"; return 0; }
	print_header() {
		local message="$1"
		printf '%s\n' "$message"
		return 0
	}
	print_warning() {
		local message="$1"
		printf 'WARN: %s\n' "$message"
		return 0
	}
	print_success() {
		local message="$1"
		printf 'OK: %s\n' "$message"
		return 0
	}
	print_info() {
		local message="$1"
		printf 'INFO: %s\n' "$message"
		return 0
	}
	cmd_upgrade_planning() { printf 'UNEXPECTED_UPGRADE\n'; return 1; }
	_update_check_planning
	printf 'AFTER_PLANNING\n'
	exit 0
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/agents/templates" "$TEST_ROOT/project/todo"
export AGENTS_DIR="$TEST_ROOT/agents"
export TEST_PROJECT="$TEST_ROOT/project"
printf '{"features":{"planning":true}}\n' >"$TEST_PROJECT/.aidevops.json"
printf '<!--TOON:meta{version}:\n2.0,todo-md+toon\n-->\n' >"$AGENTS_DIR/templates/todo-template.md"
printf '<!--TOON:meta{version}:\n2.0,plans-md+toon\n-->\n' >"$AGENTS_DIR/templates/plans-template.md"

run_check() {
	local shell_bin="$1"
	# A separate strict shell is essential: calling the function in an if/||
	# context would disable errexit and conceal the original regression.
	"$shell_bin" "$SCRIPT_DIR/test-aidevops-update-planning.sh" --check
	return $?
}

assert_output() {
	local expected="$1"
	local output="$2"
	if [[ "$output" != *"$expected"* || "$output" != *"AFTER_PLANNING"* || "$output" == *"UNEXPECTED_UPGRADE"* ]]; then
		printf 'FAIL: expected %s and continuation without upgrades\n%s\n' "$expected" "$output" >&2
		return 1
	fi
	return 0
}

for shell_bin in bash /bin/bash; do
	printf '# Legacy TODO\n- [ ] t1 Preserve this task\n' >"$TEST_PROJECT/TODO.md"
	output=$(run_check "$shell_bin" </dev/null)
	assert_output 'project (vnone)' "$output"
	assert_output 'Latest template: v2.0' "$output"
	assert_output "Run 'aidevops upgrade-planning'" "$output"
	printf 'PASS: %s legacy TODO and EOF continue without mutation\n' "$shell_bin"

	# Non-TTY input must not trigger a repository-wide upgrade or be consumed.
	output=$(printf 'y\n' | run_check "$shell_bin")
	assert_output "Run 'aidevops upgrade-planning'" "$output"
	printf 'PASS: %s noninteractive input cannot approve upgrades\n' "$shell_bin"

	printf '<!--TOON:meta{version}:\n1.0,todo-md+toon\n-->\n' >"$TEST_PROJECT/TODO.md"
	output=$(run_check "$shell_bin" </dev/null)
	assert_output 'project (v1.0)' "$output"
	printf 'PASS: %s versioned outdated TODO continues\n' "$shell_bin"

	rm "$TEST_PROJECT/TODO.md"
	printf '# Legacy plans\n' >"$TEST_PROJECT/todo/PLANS.md"
	output=$(run_check "$shell_bin" </dev/null)
	assert_output 'project (vnone)' "$output"
	printf 'PASS: %s plans-only project continues\n' "$shell_bin"
	rm "$TEST_PROJECT/todo/PLANS.md"

	printf '<!--TOON:meta{version}:\n2.0,todo-md+toon\n-->\n' >"$TEST_PROJECT/TODO.md"
	output=$(run_check "$shell_bin" </dev/null)
	assert_output 'All planning templates are up to date' "$output"
	printf 'PASS: %s current TODO remains a no-op\n' "$shell_bin"

	printf '# Legacy TODO\n' >"$TEST_PROJECT/TODO.md"
	printf '# Template without metadata\n' >"$AGENTS_DIR/templates/todo-template.md"
	output=$(run_check "$shell_bin" </dev/null)
	assert_output 'Latest template: vnone' "$output"
	printf 'PASS: %s missing template metadata remains advisory\n' "$shell_bin"
	printf '<!--TOON:meta{version}:\n2.0,todo-md+toon\n-->\n' >"$AGENTS_DIR/templates/todo-template.md"
done

printf 'All planning update regression checks passed\n'
