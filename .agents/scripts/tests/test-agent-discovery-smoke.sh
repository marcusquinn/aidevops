#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Smoke test: verify the two agent-discovery Python scripts import and run to
# completion against a fixture agents directory. Guards against regressions
# like GH#19396 (t2130 refactor shipped a signature mismatch that crashed
# both scripts, leaving user installs with zero deployed agents).
#
# The test is deliberately minimal: we don't assert on the JSON config
# contents (the full deploy path does that). We only assert that both scripts
# exit 0 after touching every line of their discovery + MCP-config paths with
# a non-empty agents directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit
SCRIPTS_DIR="$REPO_ROOT/.agents/scripts"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT

	# Fixture: a minimal agents directory with one primary agent that
	# exercises the subagent validation path (declares a task permission
	# against a known-good subagent and a known-missing one).
	mkdir -p "$TEST_DIR/agents/build-plus"

	cat >"$TEST_DIR/agents/build-plus.md" <<'EOF'
---
mode: primary
subagents:
  - research
  - nonexistent-subagent
---
# Build+
Primary agent for testing.
EOF

	cat >"$TEST_DIR/agents/research.md" <<'EOF'
---
mode: subagent
---
# Research
Fixture subagent.
EOF

	# Opencode config target so the script has somewhere to write.
	# Use printf to emit literal $schema JSON key without shell expansion.
	mkdir -p "$TEST_DIR/opencode-config"
	printf '{"%sschema":"https://opencode.ai/config.json"}\n' '$' \
		>"$TEST_DIR/opencode-config/opencode.json"

	# Claude settings target.
	mkdir -p "$TEST_DIR/claude-home/.claude"
	echo '{}' >"$TEST_DIR/claude-home/.claude/settings.json"

	return 0
}

teardown() {
	if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# Runs a discovery script with HOME pointed at the fixture tree so that
# `os.path.expanduser("~/.aidevops/agents")` and similar calls resolve into
# our sandbox rather than the real user's deployment.
run_discovery_script() {
	local script_path="$1"
	shift
	local fake_home="$TEST_DIR/fake-home"
	mkdir -p "$fake_home/.aidevops" "$fake_home/.config/opencode" "$fake_home/.claude"

	# Link fixture agents into the fake HOME layout.
	ln -sfn "$TEST_DIR/agents" "$fake_home/.aidevops/agents"
	cp "$TEST_DIR/opencode-config/opencode.json" \
		"$fake_home/.config/opencode/opencode.json"
	cp "$TEST_DIR/claude-home/.claude/settings.json" \
		"$fake_home/.claude/settings.json"

	HOME="$fake_home" python3 "$script_path" "$@"
}

test_agent_discovery_runs() {
	local output
	if output=$(run_discovery_script "$SCRIPTS_DIR/agent-discovery.py" \
		dummy opencode-json 2>&1); then
		print_result "agent-discovery.py completes without TypeError" 0
	else
		print_result "agent-discovery.py completes without TypeError" 1 "$output"
	fi
	return 0
}

test_opencode_agent_discovery_runs() {
	local output
	if output=$(run_discovery_script \
		"$SCRIPTS_DIR/opencode-agent-discovery.py" 2>&1); then
		print_result "opencode-agent-discovery.py completes without TypeError" 0
	else
		print_result "opencode-agent-discovery.py completes without TypeError" 1 "$output"
	fi
	return 0
}

test_missing_subagent_warning() {
	# The fixture declares a nonexistent subagent; both scripts should surface
	# a warning on stderr but still exit 0. Guards against the validator being
	# silently skipped.
	local output
	output=$(run_discovery_script "$SCRIPTS_DIR/agent-discovery.py" \
		dummy opencode-json 2>&1) || true
	if echo "$output" | grep -q "nonexistent-subagent"; then
		print_result "agent-discovery.py warns about missing subagent refs" 0
	else
		print_result "agent-discovery.py warns about missing subagent refs" 1 \
			"expected 'nonexistent-subagent' warning in output, got: $output"
	fi
	return 0
}

test_validate_subagent_refs_default_arg() {
	# Calling validate_subagent_refs with two positional args (the GH#19396
	# regression shape) must now succeed. Three-arg and explicit-None calls
	# must continue to work.
	local output rc py_out
	py_out=$(mktemp)
	SCRIPTS_DIR="$SCRIPTS_DIR" HOME="$TEST_DIR/fake-home" python3 - >"$py_out" 2>&1 <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"] + "/lib")
from subagent_validation import validate_subagent_refs
from agent_config import display_to_filename

agents_dir = os.path.expanduser("~/.aidevops/agents")

# 2-arg: the GH#19396 call shape. Must no longer raise TypeError.
r_default = validate_subagent_refs({}, agents_dir)
assert isinstance(r_default, list), "default-arg call returned non-list"

# 3-arg: backward-compat explicit fn.
r_explicit = validate_subagent_refs({}, agents_dir, display_to_filename)
assert isinstance(r_explicit, list), "explicit-fn call returned non-list"

# Explicit None: equivalent to default.
r_none = validate_subagent_refs({}, agents_dir, None)
assert isinstance(r_none, list), "None-fn call returned non-list"

print("OK")
PYEOF
	rc=$?
	output=$(cat "$py_out")
	rm -f "$py_out"

	if [[ $rc -eq 0 && "$output" == *"OK"* ]]; then
		print_result "validate_subagent_refs supports 2/3-arg and None call shapes" 0
	else
		print_result "validate_subagent_refs supports 2/3-arg and None call shapes" 1 "$output"
	fi
	return 0
}

main() {
	setup
	test_agent_discovery_runs
	test_opencode_agent_discovery_runs
	test_missing_subagent_warning
	test_validate_subagent_refs_default_arg

	echo ""
	echo "Tests run: $TESTS_RUN, passed: $TESTS_PASSED, failed: $TESTS_FAILED"

	if [[ $TESTS_FAILED -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
