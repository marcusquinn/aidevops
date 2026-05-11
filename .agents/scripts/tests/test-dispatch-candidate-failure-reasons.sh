#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../dispatch-dedup-helper.sh"

assert_reason() {
	local signal="$1"
	local expected="$2"
	local actual
	actual=$("$HELPER" classify-blocker "$signal")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL signal=%s expected=%s actual=%s\n' "$signal" "$expected" "$actual" >&2
		return 1
	fi
	return 0
}

assert_reason 'COST_BUDGET_EXCEEDED (spent=123 budget=100)' 'cost_budget_exceeded'
assert_reason 'DISPATCH_BLOCK_REASON reason=dedup_active_claim signal=assigned to runner' 'dedup_active_claim'
assert_reason 'DISPATCH_BLOCK_REASON reason=interactive_review_hold signal=interactive review hold label present' 'interactive_review_hold'
assert_reason 'GraphQL budget below circuit-breaker threshold' 'graphql_circuit_breaker'
assert_reason 'DISPATCH_COOLDOWN_ACTIVE until=2026-05-02T23:00:00Z reason=no_worker_process' 'cooldown_no_worker_process'
assert_reason 'dispatch_with_dedup: BLOCKED #3638 in awardsapp/awardsapp — requires cryptographic approval (ever-NMR)' 'ever_nmr_without_approval'
assert_reason 'pre-dispatch validator failed: missing worker context; needs-brief label present' 'missing_worker_context'
assert_reason 'dedup.worktree_cap blocked by max worktree count' 'local_capacity_gate'
assert_reason 'external_author_gate blocked no-auto-dispatch policy' 'policy_gate'
assert_reason '' 'no_recent_log_evidence'
assert_reason 'new blocker shape not yet classified' 'unclassified_signal'

printf 'PASS dispatch-candidate-failure-reasons\n'
