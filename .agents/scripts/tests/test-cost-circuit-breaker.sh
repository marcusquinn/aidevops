#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-cost-circuit-breaker.sh — t2007 regression guard.
#
# Asserts the per-issue cost circuit breaker fires when cumulative token
# spend across all worker attempts exceeds the tier budget, and stays
# fail-open on the unhappy paths.
#
# The breaker lives in dispatch-dedup-helper.sh::_check_cost_budget and
# is wired into is_assigned() right after the parent-task short-circuit
# (see t1986). It is paired with the no-progress fail-safe (t2008) and
# the parent-task guard (t1986) — all three are different layers of
# the same dispatch-hardening initiative from the GH#18356 root cause.
#
# Modeled on test-parent-task-guard.sh (t1986) — same stub-gh harness,
# same TEST_RED/TEST_GREEN colour vars, same negative-assertion friendly
# `set +e` after sourcing.

# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits from check-cost-budget. Each assertion explicitly
# captures exit codes.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEDUP_HELPER="${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh"

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
}

# Sandbox HOME so config/state writes are side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Stub harness — fake `gh` CLI that returns canned JSON for the calls
# is_assigned and _sum_issue_token_spend make.
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
STUB_LOG="${TEST_ROOT}/gh-stub.log"
mkdir -p "$STUB_DIR"

# Fixture state files — the stub gh reads these to know what to return.
FIXTURE_ISSUE_JSON="${TEST_ROOT}/fixture-issue.json"
FIXTURE_COMMENTS_JSON="${TEST_ROOT}/fixture-comments.json"

write_stub_gh() {
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for test-cost-circuit-breaker.sh
# Logs every invocation so we can assert side-effect counts.
echo "\$@" >>"${STUB_LOG}"

# gh issue view <num> --repo <slug> --json state,assignees,labels
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	cat "${FIXTURE_ISSUE_JSON}" 2>/dev/null || echo '{}'
	exit 0
fi

# gh api repos/<slug>/issues/<num>/comments --paginate
if [[ "\$1" == "api" ]]; then
	if [[ "\$2" == "repos/"*"/issues/"*"/comments" ]]; then
		cat "${FIXTURE_COMMENTS_JSON}" 2>/dev/null || echo '[]'
		exit 0
	fi
	if [[ "\$2" == "user" ]]; then
		echo '{"login":"test-runner"}'
		exit 0
	fi
	echo '{}'
	exit 0
fi

# gh issue comment <num> --repo <slug> --body <body>
if [[ "\$1" == "issue" && "\$2" == "comment" ]]; then
	exit 0
fi

# gh issue edit <num> --repo <slug> ... (set_issue_status)
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
	exit 0
fi

# gh label list / create (ensure_status_labels_exist)
if [[ "\$1" == "label" ]]; then
	if [[ "\$2" == "list" ]]; then
		echo "[]"
		exit 0
	fi
	exit 0
fi

# gh pr list (used elsewhere — not our paths)
if [[ "\$1" == "pr" ]]; then
	echo "[]"
	exit 0
fi

exit 0
STUB
	chmod +x "${STUB_DIR}/gh"
}

write_fixture_issue() {
	local labels_json="$1"
	local assignees_json="${2:-[]}"
	local state="${3:-OPEN}"
	cat >"$FIXTURE_ISSUE_JSON" <<JSON
{"state":"${state}","assignees":${assignees_json},"labels":${labels_json}}
JSON
}

# Build a comments fixture from a list of token spends.
# Args: $1 = comma-separated token amounts, e.g. "50000,80000,200000"
write_fixture_comments() {
	local spends="$1"
	local comments=""
	local first=1
	local amount
	for amount in ${spends//,/ }; do
		if [[ "$first" -eq 0 ]]; then
			comments+=","
		fi
		first=0
		# Shape mirrors the real gh-signature-helper.sh footer
		comments+="{\"body\":\"Worker comment.\\n\\n<!-- aidevops:sig -->\\n---\\n[aidevops.sh](https://aidevops.sh) v3.7.0 plugin for [OpenCode](https://opencode.ai) v1.4.3 with claude-opus-4-6 spent 4m and ${amount} tokens on this as a headless worker.\"}"
	done
	printf '[%s]' "$comments" >"$FIXTURE_COMMENTS_JSON"
}

write_stub_gh
OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Set SCRIPT_DIR-equivalent so the helper finds its config (the real
# helper resolves it at runtime from BASH_SOURCE — no env var needed).

# =============================================================================
# Part 1 — _get_cost_budget_for_tier reads the config (or falls back)
# =============================================================================
# We invoke check-cost-budget which uses _get_cost_budget_for_tier internally.
# Indirect coverage: an over-budget spend at a known tier proves the lookup.

# Helper: run check-cost-budget capturing both stdout and exit code.
run_check_cost_budget() {
	local issue="$1" repo="$2" tier="${3:-standard}"
	output=$("$DEDUP_HELPER" check-cost-budget "$issue" "$repo" "$tier" 2>/dev/null)
	rc=$?
	return 0
}

# =============================================================================
# Assertion 1 — under budget allows dispatch (rc=1, no signal)
# =============================================================================
# tier:standard budget = 100K. Spend 30K → under budget.
write_fixture_issue '[{"name":"tier:standard"},{"name":"pulse"}]'
write_fixture_comments "30000"
run_check_cost_budget 18001 "owner/repo" "standard"
if [[ "$rc" -eq 1 && -z "$output" ]]; then
	print_result "under-budget allow (30K < 100K standard)" 0
else
	print_result "under-budget allow (30K < 100K standard)" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 2 — over budget blocks with COST_BUDGET_EXCEEDED signal
# =============================================================================
# tier:standard budget = 100K. Spend 60K + 80K = 140K → over budget.
write_fixture_issue '[{"name":"tier:standard"},{"name":"pulse"}]'
write_fixture_comments "60000,80000"
run_check_cost_budget 18002 "owner/repo" "standard"
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* && "$output" == *"attempts=2"* ]]; then
	print_result "over-budget block emits COST_BUDGET_EXCEEDED (140K > 100K, 2 attempts)" 0
else
	print_result "over-budget block emits COST_BUDGET_EXCEEDED (140K > 100K, 2 attempts)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 3 — no comments → fail-open (treated as 0 spend, allow)
# =============================================================================
write_fixture_issue '[{"name":"tier:standard"}]'
printf '[]' >"$FIXTURE_COMMENTS_JSON"
run_check_cost_budget 18003 "owner/repo" "standard"
if [[ "$rc" -eq 1 ]]; then
	print_result "no-comments fail-open (zero spend allowed)" 0
else
	print_result "no-comments fail-open (zero spend allowed)" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 4 — gh API failure → fail-open
# =============================================================================
# Make the comments fixture invalid JSON so jq fails inside the aggregator.
write_fixture_issue '[{"name":"tier:standard"}]'
printf 'not-valid-json' >"$FIXTURE_COMMENTS_JSON"
run_check_cost_budget 18004 "owner/repo" "standard"
if [[ "$rc" -eq 1 ]]; then
	print_result "gh API/parse error fail-open" 0
else
	print_result "gh API/parse error fail-open" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 5 — per-tier budget enforcement: tier:simple = 30K, spend 50K → block
# =============================================================================
write_fixture_issue '[{"name":"tier:simple"}]'
write_fixture_comments "20000,30000"
run_check_cost_budget 18005 "owner/repo" "simple"
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* && "$output" == *"tier=simple"* ]]; then
	print_result "tier:simple budget (50K > 30K) blocks" 0
else
	print_result "tier:simple budget (50K > 30K) blocks" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 6 — same spend (50K) on tier:reasoning is well under budget (300K)
# =============================================================================
write_fixture_issue '[{"name":"tier:reasoning"}]'
write_fixture_comments "20000,30000"
run_check_cost_budget 18006 "owner/repo" "reasoning"
if [[ "$rc" -eq 1 ]]; then
	print_result "tier:reasoning budget (50K < 300K) allows" 0
else
	print_result "tier:reasoning budget (50K < 300K) allows" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 7 — side-effect idempotency: when needs-maintainer-review is
# already present, _apply_cost_breaker_side_effects must NOT post a new
# `gh issue comment` call. We measure by comparing stub log lines before
# and after a second over-budget invocation on the same issue.
# =============================================================================
# Fresh log so the count is local to this assertion
: >"$STUB_LOG"
# Fixture: over budget AND needs-maintainer-review already on the issue
write_fixture_issue '[{"name":"tier:standard"},{"name":"needs-maintainer-review"}]'
write_fixture_comments "60000,80000"
run_check_cost_budget 18007 "owner/repo" "standard"
# The signal must still be emitted (so dispatch is blocked)…
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* ]]; then
	idem_signal_ok=0
else
	idem_signal_ok=1
fi
# …but no `issue comment` calls should have been logged.
if grep -qE '^issue comment ' "$STUB_LOG"; then
	idem_no_comment_ok=1
else
	idem_no_comment_ok=0
fi
if [[ "$idem_signal_ok" -eq 0 && "$idem_no_comment_ok" -eq 0 ]]; then
	print_result "side-effect idempotency (label present → no double-comment)" 0
else
	print_result "side-effect idempotency (label present → no double-comment)" 1 \
		"(signal_ok=$idem_signal_ok no_comment_ok=$idem_no_comment_ok output='$output')"
fi

# =============================================================================
# Assertion 8 — unknown tier falls back to default budget (100K)
# =============================================================================
# Spend 150K on an issue with no tier:* label → should block (default = 100K).
write_fixture_issue '[{"name":"pulse"}]'
write_fixture_comments "75000,75000"
run_check_cost_budget 18008 "owner/repo" "unknown-tier-name"
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* ]]; then
	print_result "unknown-tier falls back to default budget (150K > 100K default)" 0
else
	print_result "unknown-tier falls back to default budget (150K > 100K default)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 9 — sum-issue-token-spend CLI returns parseable spent|attempts
# =============================================================================
write_fixture_comments "10000,20000,30000"
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18009 "owner/repo" 2>/dev/null)
if [[ "$sum_output" == "60000|3" ]]; then
	print_result "sum-issue-token-spend CLI returns 'spent|attempts'" 0
else
	print_result "sum-issue-token-spend CLI returns 'spent|attempts'" 1 "(got: '$sum_output')"
fi

# =============================================================================
# Assertion 10 — historical "has used N tokens" pattern still aggregated
# =============================================================================
# Write fixture with the older signature footer wording.
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
  {"body":"Older worker.\n---\nclaude-sonnet-4-6 has used 50000 tokens on this."},
  {"body":"Newer worker.\n---\nclaude-sonnet-4-6 spent 70000 tokens on this."}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18010 "owner/repo" 2>/dev/null)
if [[ "$sum_output" == "120000|2" ]]; then
	print_result "historical 'has used' pattern aggregated alongside 'spent'" 0
else
	print_result "historical 'has used' pattern aggregated alongside 'spent'" 1 "(got: '$sum_output')"
fi

export PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
