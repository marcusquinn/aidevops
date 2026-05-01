#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for t3417: subagent_validation.py accepts OpenCode
# permission.task glob patterns only when they match flattened task names.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEST_DIR=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

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
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

run_validation_case() {
	local case_name="$1"
	local glob_ref="$2"
	local expected_missing="$3"
	local output=""
	local status=0

	output=$(PYTHONPATH="$REPO_ROOT/.agents/scripts/lib" python3 - "$TEST_DIR" "$glob_ref" 2>&1 <<'PY'
import os
import sys
from pathlib import Path

from agent_config import discover_primary_agents, display_to_filename, validate_subagent_refs

root = Path(sys.argv[1])
glob_ref = sys.argv[2]
agents_dir = root / "agents"
agents_dir.mkdir(parents=True, exist_ok=True)
tools_dir = agents_dir / "tools"
tools_dir.mkdir(parents=True, exist_ok=True)

(agents_dir / "automate.md").write_text(f"""---
name: automate
mode: subagent
subagents:
  - {glob_ref}
  - general
---
# Automate
""")

for name in ("github-cli", "gitlab-cli", "general"):
    (tools_dir / f"{name}.md").write_text(f"""---
name: {name}
mode: subagent
---
# {name}
""")

primary, _, _ = discover_primary_agents(str(agents_dir))
missing = validate_subagent_refs(primary, str(agents_dir), display_to_filename)
for agent, ref in missing:
    print(f"{agent}:{ref}")
PY
	)
	status=$?
	if [[ "$status" -ne 0 ]]; then
		print_result "$case_name" 1 "python failed: $output"
		return 0
	fi
	if [[ "$expected_missing" == "yes" ]]; then
		if [[ "$output" == *"Automate:$glob_ref"* ]]; then
			print_result "$case_name" 0
		else
			print_result "$case_name" 1 "expected missing ref, got: ${output:-<empty>}"
		fi
	else
		if [[ -z "$output" || "$output" == *"Automate: filtered"* ]]; then
			# discover_primary_agents prints filter notices; missing refs are agent:ref lines.
			if [[ "$output" == *"Automate:$glob_ref"* ]]; then
				print_result "$case_name" 1 "unexpected missing ref: $output"
			else
				print_result "$case_name" 0
			fi
		else
			print_result "$case_name" 1 "unexpected output: $output"
		fi
	fi
	return 0
}

main() {
	setup
	run_validation_case "matching basename glob is accepted" "git*" "no"
	run_validation_case "non-matching glob is rejected" "does-not-exist*" "yes"
	run_validation_case "path-style glob is rejected" "tools/git*" "yes"

	echo ""
	echo "Tests run: $TESTS_RUN"
	echo "Passed: $TESTS_PASSED"
	echo "Failed: $TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
