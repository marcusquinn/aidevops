#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#22291: private agent-source repos can publish compact
# agent-pack manifest capabilities without forcing startup-time deep reads.

set -uo pipefail

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
	mkdir -p "$agents_dir/scripts" "$agents_dir/configs" "$TEST_HOME/private-pack/.agents/example-agent"
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
      "name": "private-pack",
      "local_path": "$TEST_HOME/private-pack",
      "remote_url": "",
      "last_synced": ""
    }
  ]
}
JSON

	cat >"$TEST_HOME/private-pack/.agents/agent-pack.json" <<'JSON'
{
  "name": "Private Ops Pack",
  "version": "2.1.0",
  "domains": ["private-ops", "client-work"],
  "triggers": ["private ops", "client workflow"],
  "primary_agents": [{"name": "PrivateOps", "file": "example-agent/example-agent.md"}],
  "subagents": [{"name": "private-ops.audit", "file": "example-agent/audit.md"}],
  "commands": [{"name": "private-status", "file": "example-agent/private-status.md"}],
  "helpers": [{"name": "private-helper", "file": "example-agent/private-helper.sh"}],
  "required_secrets": [{"name": "PRIVATE_API_KEY"}],
  "outputs": [{"name": "report", "path": "~/.aidevops/.agent-workspace/work/private-pack/reports/"}],
  "sensitivity": "restricted",
  "upstream_candidate": true
}
JSON

	cat >"$TEST_HOME/private-pack/.agents/example-agent/example-agent.md" <<'EOF_AGENT'
---
mode: primary
---
# PrivateOps
EOF_AGENT
	return 0
}

teardown() {
	if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
		rm -rf "$TEST_HOME"
	fi
	return 0
}

test_sync_generates_capability_registry() {
	local output=""
	local status=0
	output=$(AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" HOME="$TEST_HOME" "$TEST_HOME/.aidevops/agents/scripts/agent-sources-helper.sh" sync 2>&1)
	status=$?
	if [[ "$status" -ne 0 ]]; then
		print_result "sync generates capability registry" 1 "$output"
		return 0
	fi

	local registry="$TEST_HOME/.aidevops/agents/agent-source-capabilities.toon"
	if grep -q '^<!--TOON:agent_source_capabilities\[1\]' "$registry" && \
		grep -q '^private-pack,Private Ops Pack,2.1.0,private-ops|client-work,private ops|client workflow,PrivateOps,private-ops.audit,private-status,private-helper,PRIVATE_API_KEY,report,restricted,true,ok$' "$registry"; then
		print_result "sync generates capability registry" 0
	else
		print_result "sync generates capability registry" 1 "capability row missing from $registry"
	fi
	return 0
}

test_subagent_index_includes_capability_registry() {
	local output=""
	local status=0
	output=$(AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" HOME="$TEST_HOME" "$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh" generate 2>&1)
	status=$?
	if [[ "$status" -ne 0 ]]; then
		print_result "subagent index includes capability registry" 1 "$output"
		return 0
	fi

	local index_file="$TEST_HOME/.aidevops/agents/subagent-index.toon"
	if grep -q '^<!--TOON:agent_source_capabilities\[1\]' "$index_file" && \
		grep -q '^private-pack,Private Ops Pack,2.1.0,private-ops|client-work,private ops|client workflow,PrivateOps,private-ops.audit,private-status,private-helper,PRIVATE_API_KEY,report,restricted,true,ok$' "$index_file"; then
		print_result "subagent index includes capability registry" 0
	else
		print_result "subagent index includes capability registry" 1 "capability row missing from index"
	fi
	return 0
}

test_check_validates_capability_cardinality() {
	local output=""
	local status=0
	output=$(AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" HOME="$TEST_HOME" "$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh" check 2>&1)
	status=$?
	if [[ "$status" -eq 0 && "$output" == *"Declared agent source capability rows: 1"* && "$output" == *"Actual agent source capability rows: 1"* ]]; then
		print_result "check validates capability cardinality" 0
	else
		print_result "check validates capability cardinality" 1 "$output"
	fi
	return 0
}

test_sync_without_node_fails_open() {
	local path_without_node="$TEST_HOME/no-node-bin"
	mkdir -p "$path_without_node"

	local cmd=""
	local cmd_path=""
	for cmd in bash cat cp dirname find grep jq ln mkdir readlink rm rsync sed; do
		cmd_path=$(command -v "$cmd")
		if [[ -n "$cmd_path" ]]; then
			ln -s "$cmd_path" "$path_without_node/$cmd"
		fi
	done

	local output=""
	local status=0
	output=$(PATH="$path_without_node" AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" HOME="$TEST_HOME" "$TEST_HOME/.aidevops/agents/scripts/agent-sources-helper.sh" sync 2>&1)
	status=$?

	local registry="$TEST_HOME/.aidevops/agents/agent-source-capabilities.toon"
	if [[ "$status" -eq 0 && "$output" == *"Node not found; skipping agent source capability registry generation."* && "$output" != *"node: command not found"* ]] && \
		grep -q '^<!--TOON:agent_source_capabilities\[0\]' "$registry"; then
		print_result "sync without node fails open" 0
	else
		print_result "sync without node fails open" 1 "$output"
	fi
	return 0
}

main() {
	setup
	test_sync_generates_capability_registry
	test_subagent_index_includes_capability_registry
	test_check_validates_capability_cardinality
	test_sync_without_node_fails_open

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
