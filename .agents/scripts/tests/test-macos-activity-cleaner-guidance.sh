#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	printf 'FAIL: %s\n' "$name" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_file_contains() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	if grep -Eq "$pattern" "${ROOT_DIR}/${file}"; then
		pass "$name"
	else
		printf '  missing pattern: %s in %s\n' "$pattern" "$file" >&2
		fail "$name"
	fi
	return 0
}

command_file=".agents/scripts/commands/macos-activity-cleaner.md"
agent_file=".agents/tools/automation/macos-activity-cleaner.md"

assert_file_contains "command routes directly to specialist" "$command_file" '^agent: macos-activity-cleaner$'
assert_file_contains "command has cross-runtime handoff" "$command_file" 'tools/automation/macos-activity-cleaner\.md'
assert_file_contains "command passes arguments" "$command_file" "Request: \\\$ARGUMENTS"
assert_file_contains "command defaults to read-only" "$command_file" 'Default to read-only'
assert_file_contains "command protects routine mode" "$command_file" 'never prompt, elevate, apply, or rollback'

assert_file_contains "agent has least-privilege write setting" "$agent_file" '^  write: false$'
assert_file_contains "agent has least-privilege edit setting" "$agent_file" '^  edit: false$'
assert_file_contains "agent forbids process arguments" "$agent_file" 'Never collect or print full process arguments'
assert_file_contains "agent distinguishes memory pressure" "$agent_file" 'Never infer pressure from.*used memory'
assert_file_contains "agent requires repeated failure evidence" "$agent_file" 'one historical non-zero exit is not a loop'
assert_file_contains "agent defines keep findings" "$agent_file" '\| .keep. \|'
assert_file_contains "agent defines safe findings" "$agent_file" '\| .safe. \|'
assert_file_contains "agent defines conditional findings" "$agent_file" '\| .conditional. \|'
assert_file_contains "agent defines legacy findings" "$agent_file" '\| .legacy. \|'
assert_file_contains "agent defines broken findings" "$agent_file" '\| .broken. \|'
assert_file_contains "agent requires itemized approval" "$agent_file" 'itemized approval'
assert_file_contains "agent uses operation verification" "$agent_file" 'verify-operation-helper\.sh check'
assert_file_contains "agent quarantines outside Trash" "$agent_file" 'transaction directory outside Trash'
assert_file_contains "agent verifies quarantine before reversibility" "$agent_file" 'Verify each quarantine destination exists'
assert_file_contains "agent protects routine mutations" "$agent_file" 'do not prompt, elevate, apply, rollback'
assert_file_contains "agent stages listener restrictions" "$agent_file" 'stage a service-level change for its next safe restart'
assert_file_contains "agent preserves active listeners" "$agent_file" 'Never kill, firewall, edit .pf., or restart an active service'

assert_file_contains "Automate can delegate cleaner" ".agents/automate.md" '^  - macos-activity-cleaner$'
assert_file_contains "domain routing includes cleaner" ".agents/reference/domain-index.md" 'tools/automation/macos-activity-cleaner\.md'
assert_file_contains "README documents cleaner" "README.md" '@macos-activity-cleaner'

printf '\nmacOS activity cleaner guidance summary: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
