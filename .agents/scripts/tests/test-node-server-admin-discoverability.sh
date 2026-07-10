#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit
VERIFY_SCRIPT="$REPO_ROOT/.agents/scripts/verify-agent-discoverability.sh"
TEST_DIR=""

cleanup() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

main() {
	TEST_DIR=$(mktemp -d)
	trap cleanup EXIT

	local fixture_agents="$TEST_DIR/agents"
	mkdir -p "$fixture_agents"

	local entry=""
	local basename=""
	for entry in "$REPO_ROOT/.agents"/*; do
		basename=$(basename "$entry")
		[[ "$basename" == "build-plus.md" ]] && continue
		ln -s "$entry" "$fixture_agents/$basename"
	done

	sed 's/^\([[:space:]]*-[[:space:]]*node-server-admin[[:space:]]*\)$/# \1/' \
		"$REPO_ROOT/.agents/build-plus.md" >"$fixture_agents/build-plus.md"

	local output=""
	local rc=0
	output=$(AIDEVOPS_AGENTS_DIR="$fixture_agents" bash "$VERIFY_SCRIPT" 2>&1) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		echo "FAIL commented node-server-admin allowlist entry was accepted"
		return 1
	fi

	if [[ "$output" != *"[FAIL] Build+: node-server-admin allowlist"* ]]; then
		echo "FAIL expected allowlist-specific failure"
		return 1
	fi

	echo "PASS commented node-server-admin allowlist entry is rejected"
	return 0
}

main "$@"
