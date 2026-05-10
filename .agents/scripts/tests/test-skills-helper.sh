#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SKILLS_HELPER="$REPO_ROOT/.agents/scripts/skills-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP_DIR=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '  %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cleanup() {
	if [[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" ]]; then
		rm -rf "$TEST_TMP_DIR"
	fi
	return 0
}

write_skill() {
	local rel_path="$1"
	local description="$2"
	local title="$3"
	local full_path="$TEST_TMP_DIR/$rel_path"

	mkdir -p "$(dirname "$full_path")"
	cat >"$full_path" <<EOF_SKILL
---
description: $description
---

# $title
EOF_SKILL
	return 0
}

setup_fixture() {
	TEST_TMP_DIR="$(mktemp -d)"
	write_skill "services/hosting/ai-gateway.md" "Cloudflare AI Gateway for AI provider routing" "AI Gateway"
	write_skill "content/model-selection.md" "Model Selection and Comparison" "Model Selection"
	write_skill "tools/ai-assistants/model-routing.md" "Cost-aware model routing" "Model Routing"
	write_skill "tools/build-agent/build-agent.md" "Composing efficient agents" "Build Agent"
	write_skill "tools/architecture/feature-slicing.md" "Feature slicing architecture guidance" "Feature Slicing"
	write_skill "reference/memory.md" "Memory system quality gates" "Memory System"
	write_skill "reference/agent-routing.md" "Agent routing and capability discovery" "Agent Routing"
	return 0
}

run_helper() {
	AIDEVOPS_AGENTS_DIR="$TEST_TMP_DIR" bash "$SKILLS_HELPER" "$@"
	return $?
}

test_search_counts_without_mixing_display_output() {
	local output=""
	output=$(run_helper search "model gateway" 2>&1)

	if [[ "$output" == *"arithmetic syntax error"* ]]; then
		print_result "search avoids arithmetic errors when displaying results" 1 "$output"
		return 0
	fi
	if [[ "$output" != *"ai-gateway"* ]]; then
		print_result "search finds multi-term gateway result" 1 "$output"
		return 0
	fi
	if [[ "$output" == *"model-selection"* ]]; then
		print_result "search filters single-term noisy matches" 1 "$output"
		return 0
	fi

	print_result "search counts and display output stay separate" 0
	return 0
}

test_browse_counts_without_mixing_display_output() {
	local output=""
	output=$(run_helper browse services/hosting 2>&1)

	if [[ "$output" == *"arithmetic syntax error"* ]]; then
		print_result "browse avoids arithmetic errors when displaying results" 1 "$output"
		return 0
	fi
	if [[ "$output" != *"Found 1 skill(s)"* ]]; then
		print_result "browse reports numeric category count" 1 "$output"
		return 0
	fi

	print_result "browse counts and display output stay separate" 0
	return 0
}

test_recommend_counts_without_mixing_display_output() {
	local output=""
	output=$(run_helper recommend "review external AI agent memory architecture for capability cataloguing" 2>&1)

	if [[ "$output" == *"arithmetic syntax error"* ]]; then
		print_result "recommend avoids arithmetic errors when displaying category results" 1 "$output"
		return 0
	fi
	if [[ "$output" != *"tools/build-agent"* || "$output" != *"reference"* || "$output" != *"tools/architecture"* ]]; then
		print_result "recommend maps abstract capability review to useful categories" 1 "$output"
		return 0
	fi

	print_result "recommend produces bounded useful category output" 0
	return 0
}

main() {
	trap cleanup EXIT
	setup_fixture

	test_search_counts_without_mixing_display_output
	test_browse_counts_without_mixing_display_output
	test_recommend_counts_without_mixing_display_output

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
