#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#22274: private agent-source repos can use the same
# core-style .agents layout as the shared framework.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEST_HOME=""
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
	TEST_HOME=$(mktemp -d)
	trap teardown EXIT

	local agents_dir="$TEST_HOME/.aidevops/agents"
	local source_dir="$TEST_HOME/private-core/.agents"
	mkdir -p "$agents_dir/scripts" "$agents_dir/configs" "$source_dir/client-ops" \
		"$source_dir/tools" "$source_dir/services" "$source_dir/workflows" \
		"$source_dir/reference" "$source_dir/scripts/commands"
	cp "$REPO_ROOT/.agents/scripts/agent-sources-helper.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT/.agents/scripts/subagent-index-helper.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT/.agents/scripts/portable-stat.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT"/.agents/scripts/shared-*.sh "$agents_dir/scripts/"
	chmod +x "$agents_dir/scripts/agent-sources-helper.sh" "$agents_dir/scripts/subagent-index-helper.sh"

	cat >"$agents_dir/configs/agent-sources.json" <<JSON
{
  "version": "1.0.0",
  "sources": [
    {
      "name": "private-core",
      "local_path": "$TEST_HOME/private-core",
      "remote_url": "",
      "last_synced": ""
    }
  ]
}
JSON

	cat >"$source_dir/client-ops.md" <<'EOF_AGENT'
---
mode: primary
---
# Client Ops
EOF_AGENT

	cat >"$source_dir/client-ops/reporting.md" <<'EOF_SUBAGENT'
---
mode: subagent
---
# Reporting
EOF_SUBAGENT

	cat >"$source_dir/tools/data-cleanup.md" <<'EOF_TOOL'
# Data Cleanup
EOF_TOOL
	cat >"$source_dir/services/private-crm.md" <<'EOF_SERVICE'
# Private CRM
EOF_SERVICE
	cat >"$source_dir/workflows/monthly-report.md" <<'EOF_WORKFLOW'
# Monthly Report
EOF_WORKFLOW
	cat >"$source_dir/reference/account-boundaries.md" <<'EOF_REFERENCE'
# Account Boundaries
EOF_REFERENCE
	cat >"$source_dir/scripts/commands/client-report.md" <<'EOF_COMMAND'
---
agent: Client Ops
---
# Client Report
EOF_COMMAND
	return 0
}

teardown() {
	if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
		rm -rf "$TEST_HOME"
	fi
	return 0
}

assert_path() {
	local test_name="$1"
	local path="$2"
	if [[ -e "$path" ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "missing $path"
	fi
	return 0
}

test_sync_preserves_core_layout() {
	local output=""
	output=$(HOME="$TEST_HOME" "$TEST_HOME/.aidevops/agents/scripts/agent-sources-helper.sh" sync 2>&1)
	local status=$?
	if [[ "$status" -ne 0 ]]; then
		print_result "sync core layout" 1 "$output"
		return 0
	fi

	local dest="$TEST_HOME/.aidevops/agents/custom/private-core"
	assert_path "root primary agent synced" "$dest/client-ops.md"
	assert_path "matching agent directory synced" "$dest/client-ops/reporting.md"
	assert_path "tools directory synced" "$dest/tools/data-cleanup.md"
	assert_path "services directory synced" "$dest/services/private-crm.md"
	assert_path "workflows directory synced" "$dest/workflows/monthly-report.md"
	assert_path "reference directory synced" "$dest/reference/account-boundaries.md"

	local primary_link="$TEST_HOME/.aidevops/agents/client-ops.md"
	if [[ -L "$primary_link" && "$(readlink "$primary_link")" == "$dest/client-ops.md" ]]; then
		print_result "root primary agent registered" 0
	else
		print_result "root primary agent registered" 1 "bad link $primary_link"
	fi

	local command_link="$TEST_HOME/.config/opencode/command/client-report.md"
	if [[ -L "$command_link" && "$(readlink "$command_link")" == "$dest/scripts/commands/client-report.md" ]]; then
		print_result "shared slash command registered" 0
	else
		print_result "shared slash command registered" 1 "bad link $command_link"
	fi
	return 0
}

test_index_discovers_core_layout() {
	local output=""
	output=$(HOME="$TEST_HOME" "$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh" generate 2>&1)
	local status=$?
	if [[ "$status" -ne 0 ]]; then
		print_result "generate subagent index" 1 "$output"
		return 0
	fi

	local index_file="$TEST_HOME/.aidevops/agents/subagent-index.toon"
	if grep -q '^custom/private-core/,custom/private-core subagents,client-ops$' "$index_file" && \
		grep -q '^custom/private-core/tools/,custom/private-core/tools subagents,data-cleanup$' "$index_file" && \
		grep -q '^custom/private-core/workflows/,custom/private-core/workflows subagents,monthly-report$' "$index_file"; then
		print_result "index includes core-style source tree" 0
	else
		print_result "index includes core-style source tree" 1 "expected custom/private-core rows missing"
	fi
	return 0
}

main() {
	setup
	test_sync_preserves_core_layout
	test_index_discovers_core_layout

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
