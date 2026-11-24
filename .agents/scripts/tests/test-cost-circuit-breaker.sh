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
mkdir -p "${HOME}/.config/aidevops"
# Public-write privacy guard requires a readable inventory even with stub gh.
# Keep historical 800K scenarios deterministic via the supported repo override.
# The framework default now measures full usage with a provisional 20M limit.
LEGACY_BUDGET_REPO="${TEST_ROOT}/legacy-budget"
mkdir -p "${LEGACY_BUDGET_REPO}/.aidevops"
printf '%s\n' COST_BUDGET_UNIT=full-v1 COST_BUDGET_SIMPLE=800000 COST_BUDGET_STANDARD=800000 COST_BUDGET_THINKING=800000 COST_BUDGET_DEFAULT=800000 \
	>"${LEGACY_BUDGET_REPO}/.aidevops/dispatch-cost-budgets.conf"
jq -n --arg path "$LEGACY_BUDGET_REPO" '{initialized_repos:[{slug:"owner/repo",path:$path}]}' \
	>"${HOME}/.config/aidevops/repos.json"
export LOGFILE="${TEST_ROOT}/pulse.log"

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
FIXTURE_TIMELINE_JSON="${TEST_ROOT}/fixture-timeline.json"
FIXTURE_PR_JSON="${TEST_ROOT}/fixture-pr.json"
FIXTURE_EARLY_PR_JSON="${TEST_ROOT}/fixture-early-pr.json"
# Collaborator permission verdict for permission lookups: a permission name,
# "404" (confirmed non-collaborator) or "fail" (API error). Default: 404.
FIXTURE_PERMISSION="${TEST_ROOT}/fixture-permission"
printf '404' >"$FIXTURE_PERMISSION"
FIXTURE_STATUS_JSON="${TEST_ROOT}/fixture-status.json"
cat >"$FIXTURE_STATUS_JSON" <<'STATUS'
{"data":{"repository":{
  "label0":{"name":"status:available","color":"0e8a16","description":"Task is available for claiming"},
  "label1":{"name":"status:queued","color":"fbca04","description":"Worker dispatched, not yet started"},
  "label2":{"name":"status:claimed","color":"f9d0c4","description":"Interactive implementation is actively claimed"},
  "label3":{"name":"status:in-progress","color":"1d76db","description":"Worker actively running"},
  "label4":{"name":"status:in-review","color":"5319e7","description":"Non-draft PR ready for review/merge"},
  "label5":{"name":"status:done","color":"6f42c1","description":"Task is complete"},
  "label6":{"name":"status:blocked","color":"d93f0b","description":"Partial work blocked; inspect reason and next action"}
}}}
STATUS

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
	# Exact batched status-label snapshot used by ensure_status_labels_exist.
	if [[ "\$2" == "graphql" ]]; then
		cat "${FIXTURE_STATUS_JSON}"
		exit 0
	fi
	if [[ "\$2" == "repos/owner/repo" ]]; then
		printf 'false\n'
		exit 0
	fi
	if [[ "\$2" == "repos/"*"/issues/"*"/comments" ]]; then
		if [[ " \$* " == *" --slurp "* ]]; then
			jq -s '.' "${FIXTURE_COMMENTS_JSON}" 2>/dev/null || exit 1
			exit 0
		fi
		cat "${FIXTURE_COMMENTS_JSON}" 2>/dev/null || echo '[]'
		exit 0
	fi
	if [[ "\$2" == "repos/"*"/issues/"*"/timeline" ]]; then
		jq -s '.' "${FIXTURE_TIMELINE_JSON}" 2>/dev/null || exit 1
		exit 0
	fi
	[[ " \$* " == *"/collaborators/"*"/permission "* ]] && exec "${STUB_DIR}/gh-permission" "\$@"
	if [[ "\$2" == "repos/"*"/pulls/"* ]]; then
		if [[ "\$2" == "repos/owner/repo/pulls/41" ]]; then
			cat "${FIXTURE_EARLY_PR_JSON}" 2>/dev/null || exit 1
			exit 0
		fi
		cat "${FIXTURE_PR_JSON}" 2>/dev/null || exit 1
		exit 0
	fi
	if [[ "\$2" == "user" ]]; then
		echo '{"login":"test-runner"}'
		exit 0
	fi
	if [[ "\$2" == "/repos/"*"/labels?per_page=100" ]]; then
		printf '%s\n' \\
			\$'status:available\t0e8a16\tTask is available for claiming' \\
			\$'status:queued\tfbca04\tWorker dispatched, not yet started' \\
			\$'status:claimed\tf9d0c4\tInteractive implementation is actively claimed' \\
			\$'status:in-progress\t1d76db\tWorker actively running' \\
			\$'status:in-review\t5319e7\tNon-draft PR ready for review/merge' \\
			\$'status:done\t6f42c1\tTask is complete' \\
			\$'status:blocked\td93f0b\tPartial work blocked; inspect reason and next action'
		exit 0
	fi
	# Keep this circuit-breaker test focused on its historical native mutation
	# assertions; dedicated REST wrapper tests cover the REST-first path.
	if [[ "\$2" == "/repos/"*"/issues/"* ]]; then
		exit 1
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
	write_stub_gh_permission
	return 0
}

# Collaborator permission endpoint, both the shared `gh api -i` lookup form
# and the bare `--jq .permission` fallback form (GH#34598).
write_stub_gh_permission() {
	cat >"${STUB_DIR}/gh-permission" <<STUB
#!/usr/bin/env bash
permission=\$(<"${FIXTURE_PERMISSION}")
[[ "\$permission" == "fail" ]] && exit 1
if [[ "\$2" == "-i" ]]; then
	if [[ "\$permission" == "404" ]]; then
		printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
		exit 1
	fi
	printf 'HTTP/2.0 200 OK\n\n{"permission":"%s"}\n' "\$permission"
	exit 0
fi
[[ "\$permission" == "404" ]] && exit 1
printf '%s\n' "\$permission"
exit 0
STUB
	chmod +x "${STUB_DIR}/gh-permission"
	return 0
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

write_fixture_comments_with_existing_cost_marker() {
	local spends="$1"
	write_fixture_comments "$spends"
	local tmp_json="${TEST_ROOT}/comments-with-cost-marker.json"
	jq '. + [{"body":"<!-- cost-circuit-breaker:fired tier=standard spent=900000 budget=800000 -->\nCost circuit breaker fired already."}]' \
		<"$FIXTURE_COMMENTS_JSON" >"$tmp_json"
	mv "$tmp_json" "$FIXTURE_COMMENTS_JSON"
	return 0
}

printf '[]' >"$FIXTURE_TIMELINE_JSON"
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
# tier:standard budget = 800K. Spend 30K → under budget.
write_fixture_issue '[{"name":"tier:standard"},{"name":"pulse"}]'
write_fixture_comments "30000"
run_check_cost_budget 18001 "owner/repo" "standard"
if [[ "$rc" -eq 1 && -z "$output" ]]; then
	print_result "under-budget allow (30K < 800K standard)" 0
else
	print_result "under-budget allow (30K < 800K standard)" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 2 — over budget blocks with COST_BUDGET_EXCEEDED signal
# =============================================================================
# tier:standard budget = 800K. Spend 500K + 400K = 900K → over budget.
write_fixture_issue '[{"name":"tier:standard"},{"name":"pulse"}]'
write_fixture_comments "500000,400000"
run_check_cost_budget 18002 "owner/repo" "standard"
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* && "$output" == *"attempts=2"* ]]; then
	print_result "over-budget block emits COST_BUDGET_EXCEEDED (900K > 800K, 2 attempts)" 0
else
	print_result "over-budget block emits COST_BUDGET_EXCEEDED (900K > 800K, 2 attempts)" 1 \
		"(rc=$rc output='$output')"
fi

if grep -q 'cost-circuit-breaker:fired issue=#18002 repo=owner/repo tier=standard spent=900000 budget=800000 attempts=2' "$LOGFILE" 2>/dev/null; then
	print_result "cost breaker trip writes diagnostic log line" 0
else
	print_result "cost breaker trip writes diagnostic log line" 1 "(log=$(tr '\n' ' ' <"$LOGFILE" 2>/dev/null))"
fi

if grep -q 'issue edit 18002 .*--add-label status:blocked' "$STUB_LOG" 2>/dev/null &&
	! grep -q -- '--add-label needs-maintainer-review' "$STUB_LOG" 2>/dev/null &&
	! grep -q -- '--remove-label needs-maintainer-review' "$STUB_LOG" 2>/dev/null; then
	print_result "cost breaker uses structural blocked state without mutating NMR" 0
else
	print_result "cost breaker uses structural blocked state without mutating NMR" 1 "(stub_log=$(tr '\n' ' ' <"$STUB_LOG" 2>/dev/null))"
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
# Assertion 5 — per-tier budget enforcement: tier:simple = 800K, spend 850K → block
# =============================================================================
write_fixture_issue '[{"name":"tier:simple"}]'
write_fixture_comments "400000,450000"
run_check_cost_budget 18005 "owner/repo" "simple"
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* && "$output" == *"tier=simple"* ]]; then
	print_result "tier:simple budget (850K > 800K) blocks" 0
else
	print_result "tier:simple budget (850K > 800K) blocks" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 6 — same spend (50K) on tier:thinking is well under budget (800K)
# =============================================================================
write_fixture_issue '[{"name":"tier:thinking"}]'
write_fixture_comments "20000,30000"
run_check_cost_budget 18006 "owner/repo" "thinking"
if [[ "$rc" -eq 1 ]]; then
	print_result "tier:thinking budget (50K < 800K) allows" 0
else
	print_result "tier:thinking budget (50K < 800K) allows" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 7 — side-effect idempotency uses the immutable breaker marker,
# not a legacy NMR label or generic blocked status.
# =============================================================================
# Fresh log so the count is local to this assertion
: >"$STUB_LOG"
# Fixture: over budget, structurally blocked, and already carrying the marker.
write_fixture_issue '[{"name":"tier:standard"},{"name":"status:blocked"}]'
write_fixture_comments_with_existing_cost_marker "500000,400000"
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
	print_result "side-effect idempotency (marker present → no double-comment)" 0
else
	print_result "side-effect idempotency (marker present → no double-comment)" 1 \
		"(signal_ok=$idem_signal_ok no_comment_ok=$idem_no_comment_ok output='$output')"
fi

# =============================================================================
# Assertion 8 — side-effect idempotency: when the NMR label was removed after a
# prior cost-breaker trip, re-apply the label but do NOT post another
# explanatory comment.
# =============================================================================
: >"$STUB_LOG"
write_fixture_issue '[{"name":"tier:standard"},{"name":"pulse"}]'
write_fixture_comments_with_existing_cost_marker "500000,400000"
run_check_cost_budget 18008 "owner/repo" "standard"
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* ]]; then
	prior_marker_signal_ok=0
else
	prior_marker_signal_ok=1
fi
if grep -qE '^issue edit ' "$STUB_LOG"; then
	prior_marker_label_ok=0
else
	prior_marker_label_ok=1
fi
if grep -qE '^issue comment ' "$STUB_LOG"; then
	prior_marker_no_comment_ok=1
else
	prior_marker_no_comment_ok=0
fi
if [[ "$prior_marker_signal_ok" -eq 0 && "$prior_marker_label_ok" -eq 0 && "$prior_marker_no_comment_ok" -eq 0 ]]; then
	print_result "side-effect idempotency (prior marker → relabel without double-comment)" 0
else
	print_result "side-effect idempotency (prior marker → relabel without double-comment)" 1 \
		"(signal_ok=$prior_marker_signal_ok label_ok=$prior_marker_label_ok no_comment_ok=$prior_marker_no_comment_ok output='$output')"
fi

# =============================================================================
# Assertion 9 — unknown tier falls back to default budget (800K)
# =============================================================================
# Spend 900K on an issue with no tier:* label → should block (default = 800K).
write_fixture_issue '[{"name":"pulse"}]'
write_fixture_comments "450000,450000"
run_check_cost_budget 18009 "owner/repo" "unknown-tier-name"
if [[ "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* ]]; then
	print_result "unknown-tier falls back to default budget (900K > 800K default)" 0
else
	print_result "unknown-tier falls back to default budget (900K > 800K default)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Assertion 10 — sum-issue-token-spend CLI returns parseable spent|attempts
# =============================================================================
write_fixture_comments "10000,20000,30000"
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18010 "owner/repo" 2>/dev/null)
if [[ "$sum_output" == "60000|3" ]]; then
	print_result "sum-issue-token-spend CLI returns 'spent|attempts'" 0
else
	print_result "sum-issue-token-spend CLI returns 'spent|attempts'" 1 "(got: '$sum_output')"
fi

# =============================================================================
# Assertion 11 — historical "has used N tokens" pattern still aggregated
# =============================================================================
# Write fixture with the older signature footer wording.
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
  {"body":"Older worker.\n---\nclaude-sonnet-4-6 has used 50000 tokens on this."},
  {"body":"Newer worker.\n---\nclaude-sonnet-4-6 spent 70000 tokens on this."}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18011 "owner/repo" 2>/dev/null)
if [[ "$sum_output" == "120000|2" ]]; then
	print_result "historical 'has used' pattern aggregated alongside 'spent'" 0
else
	print_result "historical 'has used' pattern aggregated alongside 'spent'" 1 "(got: '$sum_output')"
fi

# =============================================================================
# Assertion 11 — signed approval resets the cost aggregation window
# =============================================================================
# A maintainer approval after a cost trip is an explicit permission to retry.
# Historical worker spend before that approval must not immediately re-trip the
# breaker and deadlock dispatch on the same old comments.
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
  {"created_at":"2026-05-03T19:00:00Z","body":"Old worker.\n---\nclaude-sonnet-4-6 spent 900000 tokens on this as a headless worker."},
  {"created_at":"2026-05-03T19:25:00Z","body":"<!-- aidevops-signed-approval -->\nMaintainer approval."},
  {"created_at":"2026-05-03T19:30:00Z","body":"Retry worker.\n---\nclaude-sonnet-4-6 spent 50000 tokens on this as a headless worker."}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18011 "owner/repo" 2>/dev/null)
if [[ "$sum_output" == "50000|1" ]]; then
	print_result "signed approval resets cost aggregation window" 0
else
	print_result "signed approval resets cost aggregation window" 1 "(got: '$sum_output')"
fi

# =============================================================================
# Assertion 12 — completed issues never trigger cost-breaker side effects
# =============================================================================
# Completion reconciliation can inspect an issue after its successful worker
# footer has crossed the token budget.  The assignment guard must not relabel
# terminal work or file a circuit-breaker meta-issue during that window.
: >"$STUB_LOG"
write_fixture_issue '[{"name":"tier:thinking"},{"name":"status:done"}]' '[]' 'CLOSED'
write_fixture_comments "948278"
terminal_output=$(ISSUE_META_JSON="$(<"$FIXTURE_ISSUE_JSON")" \
	"$DEDUP_HELPER" is-assigned 18012 "owner/repo" 2>/dev/null)
terminal_rc=$?
if [[ "$terminal_rc" -eq 1 && -z "$terminal_output" ]] &&
	! grep -qE '^issue (edit|comment) ' "$STUB_LOG"; then
	print_result "completed issue skips over-budget breaker side effects" 0
else
	print_result "completed issue skips over-budget breaker side effects" 1 \
		"(rc=$terminal_rc output='$terminal_output' stub_log=$(tr '\n' ' ' <"$STUB_LOG" 2>/dev/null))"
fi

# Merged For/Ref/Resolves checkpoints reset spend at merge time, across pages.
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[{"created_at":"2026-05-03T19:00:00Z","body":"spent 600000 tokens"}]
[{"created_at":"2026-05-03T19:30:00Z","body":"spent 300000 tokens"}]
JSON
for reference in For Ref Resolves; do
	cat >"$FIXTURE_TIMELINE_JSON" <<JSON
[]
[{"event":"cross-referenced","created_at":"2026-05-03T18:00:00Z","source":{"issue":{"repository":{"full_name":"owner/repo"},"body":"${reference} #18013","pull_request":{"merged_at":"2026-05-03T19:25:00Z"}}}}]
JSON
	sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
	if [[ "$sum_output" == "300000|1" ]]; then
		print_result "merged ${reference} checkpoint resets spend across pages" 0
	else
		print_result "merged ${reference} checkpoint resets spend across pages" 1 "(got: '$sum_output')"
	fi
done
run_check_cost_budget 18013 "owner/repo" "standard"
if [[ "$rc" -eq 1 && -z "$output" ]]; then
	print_result "merged checkpoint keeps 300K under budget" 0
else
	print_result "merged checkpoint keeps 300K under budget" 1 "(rc=$rc output='$output')"
fi

# Timeline ordering is reference ordering, not necessarily merge ordering.
cat >"$FIXTURE_TIMELINE_JSON" <<'JSON'
[
 {"event":"cross-referenced","source":{"issue":{"repository":{"full_name":"owner/repo"},"body":"For #18013","pull_request":{"merged_at":"2026-05-03T19:25:00Z"}}}},
 {"event":"cross-referenced","source":{"issue":{"repository":{"full_name":"owner/repo"},"body":"Ref #18013","pull_request":{"merged_at":"2026-05-03T18:25:00Z"}}}}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
if [[ "$sum_output" == "300000|1" ]]; then
	print_result "latest merge wins regardless of timeline order" 0
else
	print_result "latest merge wins regardless of timeline order" 1 "(got: '$sum_output')"
fi

for marker in '<!-- cost-circuit-breaker:reset -->' '<!-- aidevops-signed-approval -->'; do
	cat >"$FIXTURE_COMMENTS_JSON" <<JSON
[
 {"created_at":"2026-05-03T19:26:00Z","body":"spent 600000 tokens"},
 {"created_at":"2026-05-03T19:28:00Z","body":"${marker}"},
 {"created_at":"2026-05-03T19:30:00Z","body":"spent 300000 tokens"},
 {"created_at":"2026-05-03T19:31:00Z","body":"spent 900000 tokens with the user in an interactive session"}
]
JSON
	sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
	if [[ "$sum_output" == "300000|1" ]]; then
		print_result "newer ${marker} overrides merge; interactive spend excluded" 0
	else
		print_result "newer ${marker} overrides merge; interactive spend excluded" 1 "(got: '$sum_output')"
	fi
done
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[{"created_at":"2026-05-03T19:00:00Z","body":"spent 600000 tokens"}]
[{"created_at":"2026-05-03T19:30:00Z","body":"spent 300000 tokens"}]
JSON

# Unmerged PRs, ordinary issues, other repositories and prefix collisions do not reset.
cat >"$FIXTURE_TIMELINE_JSON" <<'JSON'
[
 {"event":"cross-referenced","source":{"issue":{"repository":{"full_name":"owner/repo"},"body":"For #18013","pull_request":{"merged_at":null}}}},
 {"event":"cross-referenced","source":{"issue":{"repository":{"full_name":"other/repo"},"body":"For #18013","pull_request":{"merged_at":"2026-05-03T19:25:00Z"}}}},
 {"event":"cross-referenced","source":{"issue":{"repository":{"full_name":"owner/repo"},"body":"For #180130","pull_request":{"merged_at":"2026-05-03T19:25:00Z"}}}},
 {"event":"cross-referenced","source":{"issue":{"repository":{"full_name":"owner/repo"},"body":"For #18013"}}}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
run_check_cost_budget 18013 "owner/repo" "standard"
if [[ "$sum_output" == "900000|2" && "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* ]]; then
	print_result "without delivered checkpoint 900K still trips breaker" 0
else
	print_result "without delivered checkpoint 900K still trips breaker" 1 "(sum='$sum_output' rc=$rc output='$output')"
fi

printf 'not-valid-json' >"$FIXTURE_TIMELINE_JSON"
run_check_cost_budget 18013 "owner/repo" "standard"
if [[ "$rc" -eq 1 && -z "$output" ]]; then
	print_result "timeline lookup/parse failure stays fail-open" 0
else
	print_result "timeline lookup/parse failure stays fail-open" 1 "(rc=$rc output='$output')"
fi

# Missing timeline references must not erase independently verified delivery.
printf '[]' >"$FIXTURE_TIMELINE_JSON"
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[{"created_at":"2026-05-03T19:00:00Z","body":"spent 700000 tokens"}]
[{"created_at":"2026-05-03T19:26:00Z","author_association":"COLLABORATOR","body":"<!-- PARTIAL_PARENT_CLOSEOUT:PR#42 -->\nCopied summary: spent 700000 tokens"},
 {"created_at":"2026-05-03T19:30:00Z","body":"spent 300000 tokens"}]
JSON
cat >"$FIXTURE_PR_JSON" <<'JSON'
{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18013","merged_at":"2026-05-03T19:25:00Z"}
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "300000|1" ]]; then assertion_rc=0; fi
print_result "verified closeout resets missing timeline; copied footer is not spend" "$assertion_rc" "(got: '$sum_output')"

for invalid_pr in \
	'{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18013","merged_at":null}' \
	'{"base":{"repo":{"full_name":"other/repo"}},"body":"For #18013","merged_at":"2026-05-03T19:25:00Z"}' \
	'{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #180130","merged_at":"2026-05-03T19:25:00Z"}'; do
	printf '%s' "$invalid_pr" >"$FIXTURE_PR_JSON"
	sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
	assertion_rc=1
	if [[ "$sum_output" == "1000000|2" ]]; then assertion_rc=0; fi
	print_result "unverified closeout does not reset budget" "$assertion_rc" "(got: '$sum_output')"
done
printf 'not-valid-json' >"$FIXTURE_PR_JSON"
run_check_cost_budget 18013 "owner/repo" "standard"
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" ]]; then assertion_rc=0; fi
print_result "closeout PR parse failure stays fail-open" "$assertion_rc"

# GH#34251: four counted footers were two worker reports and two copied
# closeout summaries, not four consecutive failures. Timeline references were
# missing. Retain the incident's spend shape without private source data.
printf '[]' >"$FIXTURE_TIMELINE_JSON"
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-05-03T18:00:00Z","body":"spent 246727 tokens"},
 {"created_at":"2026-05-03T19:00:00Z","body":"spent 244443 tokens"},
 {"created_at":"2026-05-03T19:30:00Z","body":"spent 186376 tokens"},
 {"created_at":"2026-05-03T19:40:00Z","body":"spent 190989 tokens"}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "868535|4" ]]; then assertion_rc=0; fi
print_result "unmarked incident control counts 868535 tokens across four footers" "$assertion_rc" "(got: '$sum_output')"

# Put the newer receipt first: comment/candidate order must not pick the older
# checkpoint. Both receipts copy worker footers and neither is another attempt.
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-05-03T18:00:00Z","body":"spent 246727 tokens"},
 {"created_at":"2026-05-03T19:40:00Z","body":"spent 190989 tokens"}
]
[
 {"created_at":"2026-05-03T20:01:00Z","author_association":"MEMBER","body":"<!-- PARTIAL_PARENT_CLOSEOUT:PR#42 -->\nCopied summary: spent 186376 tokens"},
 {"created_at":"2026-05-03T18:26:00Z","author_association":"MEMBER","body":"<!-- PARTIAL_PARENT_CLOSEOUT:PR#41 -->\nCopied summary: spent 244443 tokens"}
]
JSON
cat >"$FIXTURE_EARLY_PR_JSON" <<'JSON'
{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18013","merged_at":"2026-05-03T18:25:00Z"}
JSON
cat >"$FIXTURE_PR_JSON" <<'JSON'
{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18013","merged_at":"2026-05-03T20:00:00Z"}
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18013 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "0|0" ]]; then assertion_rc=0; fi
print_result "latest verified partial delivery clears incident spend without timeline events" "$assertion_rc" "(got: '$sum_output')"
: >"$STUB_LOG"
run_check_cost_budget 18013 "owner/repo" "standard"
if [[ "$rc" -eq 1 && -z "$output" ]] &&
	! grep -qE '^issue (edit|comment) ' "$STUB_LOG"; then
	print_result "delivered incident history does not block or file another meta issue" 0
else
	print_result "delivered incident history does not block or file another meta issue" 1 "(rc=$rc output='$output')"
fi

# GH#34342: signature footers report cumulative OpenCode session time and
# tokens. A continuation dispatch that resumed the 08:00 session posted
# 89,214 → 217,569 → 356,637; summing every footer counted 809,536 after the
# 09:22 checkpoint and tripped the breaker. Anonymized incident shape.
cat >"$FIXTURE_TIMELINE_JSON" <<'JSON'
[{"event":"cross-referenced","source":{"issue":{"repository":{"full_name":"owner/repo"},"body":"For #18014","pull_request":{"merged_at":"2026-05-03T09:22:30Z"}}}}]
JSON
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-05-03T08:06:18Z","user":{"login":"runner-b"},"body":"Checkpoint.\n---\nwith model spent 6m and 89,214 tokens on this as a headless worker."},
 {"created_at":"2026-05-03T12:41:19Z","user":{"login":"runner-c"},"body":"Checkpoint.\n---\nwith model spent 13m and 147,569 tokens on this as a headless worker."},
 {"created_at":"2026-05-03T14:05:12Z","user":{"login":"runner-b"},"body":"Continuation.\n---\nwith model spent 6h 5m and 217,569 tokens on this as a headless worker."},
 {"created_at":"2026-05-03T15:19:39Z","user":{"login":"runner-a"},"body":"Blocked.\n---\nwith model spent 4m and 87,761 tokens on this as a headless worker."},
 {"created_at":"2026-05-03T21:02:24Z","user":{"login":"runner-b"},"body":"Continuation.\n---\nwith model spent 13h 2m and 356,637 tokens on this as a headless worker."}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "502753|4" ]]; then assertion_rc=0; fi
print_result "resumed-session footers count increments, pre-window footer is baseline" "$assertion_rc" "(got: '$sum_output')"
: >"$STUB_LOG"
run_check_cost_budget 18014 "owner/repo" "standard"
if [[ "$rc" -eq 1 && -z "$output" ]] && ! grep -qE '^issue (edit|comment) ' "$STUB_LOG"; then
	print_result "resumed-session incident history stays under budget" 0
else
	print_result "resumed-session incident history stays under budget" 1 "(rc=$rc output='$output')"
fi

# Separate sessions by the same author (different implied start) still sum.
printf '[]' >"$FIXTURE_TIMELINE_JSON"
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-05-03T10:00:00Z","user":{"login":"runner-b"},"body":"spent 5m and 400,000 tokens"},
 {"created_at":"2026-05-03T11:00:00Z","user":{"login":"runner-b"},"body":"spent 5m and 500,000 tokens"},
 {"created_at":"2026-05-03T11:30:00Z","user":{"login":"runner-c"},"body":"spent 1h 35m and 600,000 tokens"}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "1500000|3" ]]; then assertion_rc=0; fi
print_result "distinct sessions and other authors are not merged" "$assertion_rc" "(got: '$sum_output')"

# GH#34510: a partial closeout can be the only footer carrying the resumed
# session baseline. It arrives just after the verified merge, but is neither
# new spend nor an attempt. Dropping it charges the full session again.
cat >"$FIXTURE_PR_JSON" <<'JSON'
{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18014","merged_at":"2026-05-04T18:44:24Z"}
JSON
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-05-04T18:44:37Z","user":{"login":"runner-b"},"author_association":"MEMBER","body":"<!-- PARTIAL_PARENT_CLOSEOUT:PR#42 -->\nspent 1d 3h and 1,150,739 tokens as a headless worker"},
 {"created_at":"2026-05-04T20:06:53Z","user":{"login":"runner-b"},"body":"spent 1d 5h and 1,393,983 tokens as a headless worker"}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "243244|1" ]]; then assertion_rc=0; fi
print_result "merged receipt preserves resumed-session baseline without another attempt" "$assertion_rc" "(got: '$sum_output')"
: >"$STUB_LOG"
run_check_cost_budget 18014 "owner/repo" "thinking"
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" ]] && ! grep -qE '^issue (edit|comment) ' "$STUB_LOG"; then assertion_rc=0; fi
print_result "resumed worker after merged receipt does not falsely trip thinking budget" "$assertion_rc" "(rc=$rc output='$output')"

# Receipt metadata cannot reduce a different session or an unverified delivery.
receipt_fixture=$(<"$FIXTURE_COMMENTS_JSON")
for receipt_filter in \
	'.[0].author_association = "NONE"' \
	'.[0].user.login = "other-runner"' \
	'.[0].created_at = "2026-05-04T18:47:37Z"' \
	'.[0].body |= sub("1d 3h"; "5m")'; do
	printf '%s' "$receipt_fixture" | jq "$receipt_filter" >"$FIXTURE_COMMENTS_JSON"
	sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
	assertion_rc=1
	if [[ "$sum_output" == "1393983|1" ]]; then assertion_rc=0; fi
	print_result "receipt baseline rejects $receipt_filter" "$assertion_rc" "(got: '$sum_output')"
done
printf '%s' "$receipt_fixture" >"$FIXTURE_COMMENTS_JSON"
for invalid_pr in \
	'{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18014","merged_at":null}' \
	'{"base":{"repo":{"full_name":"other/repo"}},"body":"For #18014","merged_at":"2026-05-04T18:44:24Z"}' \
	'{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #180140","merged_at":"2026-05-04T18:44:24Z"}'; do
	printf '%s' "$invalid_pr" >"$FIXTURE_PR_JSON"
	sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
	assertion_rc=1
	if [[ "$sum_output" == "1393983|1" ]]; then assertion_rc=0; fi
	print_result "unverified receipt cannot supply a session baseline" "$assertion_rc" "(got: '$sum_output')"
done

# GH#34598: installation-authenticated REST reports private org members as
# CONTRIBUTOR. Association-only trust dropped every closeout receipt, the
# timeline lacked the cross-references, and delivered work was re-charged
# (incident: 931421|6 instead of 0|0). Write permission must restore the
# receipt; a confirmed non-collaborator must not; lookup failure fails open.
printf '[]' >"$FIXTURE_TIMELINE_JSON"
cat >"$FIXTURE_PR_JSON" <<'JSON'
{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18015","merged_at":"2026-05-05T12:00:00Z"}
JSON
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-05-05T10:00:00Z","user":{"login":"runner-a"},"author_association":"CONTRIBUTOR","body":"spent 5m and 500,000 tokens"},
 {"created_at":"2026-05-05T11:00:00Z","user":{"login":"runner-a"},"author_association":"CONTRIBUTOR","body":"spent 5m and 450,000 tokens"},
 {"created_at":"2026-05-05T12:00:20Z","user":{"login":"runner-a"},"author_association":"CONTRIBUTOR","body":"<!-- PARTIAL_PARENT_CLOSEOUT:PR#42 -->\nspent 5m and 100,000 tokens"},
 {"created_at":"2026-05-05T13:00:00Z","user":{"login":"runner-b"},"author_association":"CONTRIBUTOR","body":"spent 5m and 120,000 tokens"}
]
JSON
printf 'write' >"$FIXTURE_PERMISSION"
: >"$STUB_LOG"
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18015 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "120000|1" ]] && grep -q 'collaborators/runner-a/permission' "$STUB_LOG" &&
	! grep -q 'collaborators/runner-b/permission' "$STUB_LOG"; then
	assertion_rc=0
fi
print_result "write-permission CONTRIBUTOR receipt resets delivered spend" "$assertion_rc" "(got: '$sum_output')"
run_check_cost_budget 18015 "owner/repo" "thinking"
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" ]]; then assertion_rc=0; fi
print_result "permission-verified receipt prevents false thinking-budget trip" "$assertion_rc" "(rc=$rc output='$output')"
printf '404' >"$FIXTURE_PERMISSION"
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18015 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "1070000|3" ]]; then assertion_rc=0; fi
print_result "non-collaborator receipt cannot reset spend" "$assertion_rc" "(got: '$sum_output')"
printf 'read' >"$FIXTURE_PERMISSION"
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18015 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "1070000|3" ]]; then assertion_rc=0; fi
print_result "read-permission receipt cannot reset spend" "$assertion_rc" "(got: '$sum_output')"
printf 'fail' >"$FIXTURE_PERMISSION"
run_check_cost_budget 18015 "owner/repo" "thinking"
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" ]]; then assertion_rc=0; fi
print_result "permission lookup failure stays fail-open" "$assertion_rc" "(rc=$rc output='$output')"
printf '404' >"$FIXTURE_PERMISSION"

# Merged checkpoints reported only as "PR #N" in trusted signed worker comments
# are verified through REST; unreadable mentions are skipped, never fail-open.
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-05-03T18:00:00Z","body":"spent 700000 tokens"},
 {"created_at":"2026-05-03T19:26:00Z","author_association":"MEMBER","body":"Checkpoint merged in PR #43.\n<!-- aidevops:sig -->\n---\nspent 200000 tokens"},
 {"created_at":"2026-05-03T19:30:00Z","body":"spent 300000 tokens"}
]
JSON
cat >"$FIXTURE_PR_JSON" <<'JSON'
{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18014","merged_at":"2026-05-03T19:25:00Z"}
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "300000|1" ]]; then assertion_rc=0; fi
print_result "verified PR mention in signed worker report resets spend" "$assertion_rc" "(got: '$sum_output')"
printf 'not-valid-json' >"$FIXTURE_PR_JSON"
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "1200000|3" ]]; then assertion_rc=0; fi
print_result "unreadable PR mention is skipped without failing open" "$assertion_rc" "(got: '$sum_output')"

# GH#39969: no timeline events or closeout markers, only a signed Markdown
# PR URL posted 55 seconds after merge. Its cumulative footer is delivered work,
# not a new 7M-token failure. The resumed session charges only subsequent usage.
cat >"$FIXTURE_PR_JSON" <<'JSON'
{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18014","merged_at":"2026-05-03T19:25:00Z"}
JSON
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
  {"created_at":"2026-05-03T18:00:00Z","body":"spent 700000 tokens"},
  {"created_at":"2026-05-03T19:25:55Z","author_association":"MEMBER","user":{"login":"runner"},"body":"Merged [checkpoint](https://github.com/owner/repo/pull/43).\n<!-- aidevops:sig -->\n<!-- aidevops:usage:full-v1 -->\nspent 1h and 7,262,638 tokens"},
  {"created_at":"2026-05-03T19:30:55Z","author_association":"MEMBER","user":{"login":"runner"},"body":"<!-- aidevops:usage:full-v1 -->\nspent 1h 5m and 7,302,638 tokens"}
]
JSON
URL_REPORT_FIXTURE=$(<"$FIXTURE_COMMENTS_JSON")
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "40000|1" ]]; then assertion_rc=0; fi
print_result "verified Markdown PR URL supplies merged-session baseline" "$assertion_rc" "(got: '$sum_output')"
for report_filter in \
	'.[1].author_association = "NONE"' \
	'.[1].body |= sub("owner/repo/pull"; "other/repo/pull")' \
	'.[1].body |= sub("https://github.com"; "https://example.com")' \
	'.[1].body |= sub("<!-- aidevops:sig -->"; "unsigned")'; do
	printf '%s' "$URL_REPORT_FIXTURE" | jq "$report_filter" >"$FIXTURE_COMMENTS_JSON"
	sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
	assertion_rc=1
	if [[ "$sum_output" == "8002638|3" ]]; then assertion_rc=0; fi
	print_result "URL checkpoint rejects $report_filter" "$assertion_rc" "(got: '$sum_output')"
done
# A stale copy can nominate a verified checkpoint but cannot erase later usage.
printf '%s' "$URL_REPORT_FIXTURE" | jq '.[1].created_at = "2026-05-03T19:28:00Z"' >"$FIXTURE_COMMENTS_JSON"
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "7302638|2" ]]; then assertion_rc=0; fi
print_result "delayed signed URL report remains chargeable" "$assertion_rc" "(got: '$sum_output')"
printf '%s' "$URL_REPORT_FIXTURE" >"$FIXTURE_COMMENTS_JSON"
for pr_filter in '.merged_at = null' '.body = "For #99999"' '.base.repo.full_name = "other/repo"'; do
	printf '%s' '{"base":{"repo":{"full_name":"owner/repo"}},"body":"For #18014","merged_at":"2026-05-03T19:25:00Z"}' |
		jq "$pr_filter" >"$FIXTURE_PR_JSON"
	sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18014 "owner/repo" 2>/dev/null)
	assertion_rc=1
	if [[ "$sum_output" == "8002638|3" ]]; then assertion_rc=0; fi
	print_result "URL checkpoint requires verified merge: $pr_filter" "$assertion_rc" "(got: '$sum_output')"
done

# =============================================================================
# t18729 — repository budget override from a committed
# .aidevops/dispatch-cost-budgets.conf (parsed as data, clamped, never sourced)
# =============================================================================
printf '[]' >"$FIXTURE_TIMELINE_JSON"
BUDGET_REPO="${TEST_ROOT}/repos/budgeted"
BUDGET_MARKER="${TEST_ROOT}/sourced-marker"
mkdir -p "${BUDGET_REPO}/.aidevops"
jq -n --arg path "$BUDGET_REPO" --arg legacy "$LEGACY_BUDGET_REPO" \
	'{initialized_repos: [{slug: "owner/budgeted", path: $path}, {slug:"owner/repo",path:$legacy}]}' \
	>"${HOME}/.config/aidevops/repos.json"
cat >"${BUDGET_REPO}/.aidevops/dispatch-cost-budgets.conf" <<CONF
# Repository budget override
COST_BUDGET_STANDARD=2000000
COST_BUDGET_THINKING=1; touch ${BUDGET_MARKER}
COST_BUDGET_SIMPLE=5
CONF

write_fixture_issue '[{"name":"tier:standard"}]'
write_fixture_comments "500000,400000"
run_check_cost_budget 18101 "owner/budgeted" "standard"
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" ]]; then assertion_rc=0; fi
print_result "repository override raises standard budget (900K < 2M)" "$assertion_rc" "(rc=$rc output='$output')"

run_check_cost_budget 18102 "owner/repo" "standard"
assertion_rc=1
if [[ "$rc" -eq 0 && "$output" == *"budget=800K"* ]]; then assertion_rc=0; fi
print_result "repository without override keeps 800K budget" "$assertion_rc" "(rc=$rc output='$output')"

run_check_cost_budget 18103 "owner/budgeted" "thinking"
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" && ! -e "$BUDGET_MARKER" ]]; then assertion_rc=0; fi
print_result "malformed override line is ignored and never executed" "$assertion_rc" "(rc=$rc output='$output' marker=$([[ -e "$BUDGET_MARKER" ]] && printf present || printf absent))"

write_fixture_comments "150000"
run_check_cost_budget 18104 "owner/budgeted" "simple"
assertion_rc=1
if [[ "$rc" -eq 0 && "$output" == *"budget=100K"* ]]; then assertion_rc=0; fi
print_result "override below the minimum is clamped to 100K" "$assertion_rc" "(rc=$rc output='$output')"

# GH#40030: a legacy-unit override (no COST_BUDGET_UNIT=full-v1) written
# against the old 800K default must not trip on one ordinary full-usage
# attempt. 2M legacy scales to 50M and clamps to the 20M maximum.
write_fixture_comments "6515070"
run_check_cost_budget 18105 "owner/budgeted" "standard"
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" ]]; then assertion_rc=0; fi
print_result "legacy 2M override allows a single 6.5M full-usage attempt" "$assertion_rc" "(rc=$rc output='$output')"
write_fixture_comments "21000000"
run_check_cost_budget 18106 "owner/budgeted" "standard"
assertion_rc=1
if [[ "$rc" -eq 0 && "$output" == *"budget=20000K"* ]]; then assertion_rc=0; fi
print_result "scaled legacy override still clamps to the 20M maximum" "$assertion_rc" "(rc=$rc output='$output')"
# A declared full-usage override is honoured verbatim (CRLF tolerated).
printf 'COST_BUDGET_UNIT=full-v1\r\nCOST_BUDGET_STANDARD=2000000\r\n' \
	>"${BUDGET_REPO}/.aidevops/dispatch-cost-budgets.conf"
write_fixture_comments "6515070"
run_check_cost_budget 18107 "owner/budgeted" "standard"
assertion_rc=1
if [[ "$rc" -eq 0 && "$output" == *"budget=2000K"* ]]; then assertion_rc=0; fi
print_result "declared full-v1 override is applied without scaling" "$assertion_rc" "(rc=$rc output='$output')"
jq -n --arg path "$LEGACY_BUDGET_REPO" '{initialized_repos:[{slug:"owner/repo",path:$path}]}' \
	>"${HOME}/.config/aidevops/repos.json"

# =============================================================================
# GH#38272 — updatedAt-keyed spend cache and final-guard skip
# =============================================================================
export AIDEVOPS_STATE_DIR="${TEST_ROOT}/state"
CACHE_TS="2026-11-14T10:00:00Z"
CACHE_META="{\"state\":\"OPEN\",\"assignees\":[],\"labels\":[{\"name\":\"tier:standard\"}],\"updatedAt\":\"${CACHE_TS}\"}"

# Run _check_cost_budget with issue metadata (the is_assigned path) in a fresh
# process, like each is-assigned subprocess.
run_cached_check() {
	local issue="$1" meta="$2"
	output=$(bash -c '
		SCRIPT_DIR="$1"
		source "${SCRIPT_DIR}/shared-constants.sh"
		source "${SCRIPT_DIR}/dispatch-dedup-cost.sh"
		_check_cost_budget "$2" "owner/repo" "standard" "$3"
	' _ "$TEST_SCRIPTS_DIR" "$issue" "$meta" 2>/dev/null)
	rc=$?
	return 0
}
count_comment_calls() {
	local issue="$1"
	grep -c "issues/${issue}/comments" "$STUB_LOG" 2>/dev/null || true
	return 0
}

write_fixture_issue '[{"name":"tier:standard"}]'
write_fixture_comments "30000"
run_cached_check 18201 "$CACHE_META"
calls_first=$(count_comment_calls 18201)
run_cached_check 18201 "$CACHE_META"
calls_second=$(count_comment_calls 18201)
assertion_rc=1
if [[ "$rc" -eq 1 && "$calls_first" -ge 1 && "$calls_second" -eq "$calls_first" ]]; then assertion_rc=0; fi
print_result "unchanged updatedAt reuses cached spend (no second comments call)" "$assertion_rc" "(first=$calls_first second=$calls_second rc=$rc)"

# A cache hit returns the same budget decision (over-budget stays blocked).
write_fixture_comments "500000,400000"
run_cached_check 18202 "$CACHE_META"
rc_first=$rc
run_cached_check 18202 "$CACHE_META"
assertion_rc=1
if [[ "$rc_first" -eq 0 && "$rc" -eq 0 && "$output" == *"COST_BUDGET_EXCEEDED"* ]]; then assertion_rc=0; fi
print_result "cache hit keeps the over-budget decision" "$assertion_rc" "(rc=$rc output='$output')"

# Changed updatedAt recomputes.
calls_before=$(count_comment_calls 18201)
run_cached_check 18201 "${CACHE_META/10:00:00Z/10:05:00Z}"
calls_after=$(count_comment_calls 18201)
assertion_rc=1
if [[ "$calls_after" -gt "$calls_before" ]]; then assertion_rc=0; fi
print_result "changed updatedAt recomputes spend" "$assertion_rc" "(before=$calls_before after=$calls_after)"

# Entries older than the TTL recompute.
AIDEVOPS_DISPATCH_COST_CACHE_TTL_SECONDS=1 run_cached_check 18201 "${CACHE_META/10:00:00Z/10:05:00Z}"
calls_before=$(count_comment_calls 18201)
sleep 2
AIDEVOPS_DISPATCH_COST_CACHE_TTL_SECONDS=1 run_cached_check 18201 "${CACHE_META/10:00:00Z/10:05:00Z}"
calls_after=$(count_comment_calls 18201)
assertion_rc=1
if [[ "$calls_after" -gt "$calls_before" ]]; then assertion_rc=0; fi
print_result "expired cache entry recomputes spend" "$assertion_rc" "(before=$calls_before after=$calls_after)"

# Final claim guard skips the cost gate via AIDEVOPS_DDH_SKIP_COST_BUDGET=1.
write_fixture_issue '[{"name":"tier:standard"}]'
write_fixture_comments "500000,400000"
guard_out=$("$DEDUP_HELPER" is-assigned 18203 "owner/repo" "test-runner" 2>/dev/null)
guard_out_skip=$(AIDEVOPS_DDH_SKIP_COST_BUDGET=1 "$DEDUP_HELPER" is-assigned-read-only 18203 "owner/repo" "test-runner" 2>/dev/null)
assertion_rc=1
if [[ "$guard_out" == *"COST_BUDGET_EXCEEDED"* && "$guard_out_skip" != *"COST_BUDGET_EXCEEDED"* ]]; then assertion_rc=0; fi
print_result "skip env bypasses cost gate only for the final guard" "$assertion_rc" "(normal='$guard_out' skip='$guard_out_skip')"
unset AIDEVOPS_STATE_DIR

# GH#39951: equivalent full-usage footers share a scale across providers.
printf '[]' >"$FIXTURE_PR_JSON"
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"body":"claude-sonnet-5-5 spent 1,507,013 tokens on this as a headless worker. <!-- aidevops:usage:full-v1 -->"},
 {"body":"gpt-6.1-sol spent 1,507,013 tokens on this as a headless worker. <!-- aidevops:usage:full-v1 -->"}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18301 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "3014026|2" ]]; then assertion_rc=0; fi
print_result "Anthropic and OpenAI full-usage footers aggregate on the same scale" "$assertion_rc" "(got: '$sum_output')"

# A legacy baseline is never subtracted from a different accounting unit.
cat >"$FIXTURE_COMMENTS_JSON" <<'JSON'
[
 {"created_at":"2026-11-20T10:05:00Z","user":{"login":"worker"},"body":"spent 5m and 20,000 tokens"},
 {"created_at":"2026-11-20T10:10:00Z","user":{"login":"worker"},"body":"spent 10m and 1,500,000 tokens <!-- aidevops:usage:full-v1 -->"},
 {"created_at":"2026-11-20T10:15:00Z","user":{"login":"worker"},"body":"spent 15m and 2,000,000 tokens <!-- aidevops:usage:full-v1 -->"}
]
JSON
sum_output=$("$DEDUP_HELPER" sum-issue-token-spend 18302 "owner/repo" 2>/dev/null)
assertion_rc=1
if [[ "$sum_output" == "2020000|3" ]]; then assertion_rc=0; fi
print_result "legacy and full counters remain separate while full continuations deduplicate" "$assertion_rc" "(got: '$sum_output')"

# No override: full-usage default allows a typical 1.5M attempt but trips at 21M.
write_fixture_comments "1507013"
run_check_cost_budget 18303 "owner/defaults" standard
assertion_rc=1
if [[ "$rc" -eq 1 && -z "$output" ]]; then assertion_rc=0; fi
print_result "full-usage default allows ordinary 1.5M attempt" "$assertion_rc"
write_fixture_comments "21000000"
run_check_cost_budget 18304 "owner/defaults" standard
assertion_rc=1
if [[ "$rc" -eq 0 && "$output" == *"budget=20000K"* ]]; then assertion_rc=0; fi
print_result "full-usage default stops runaway above 20M" "$assertion_rc" "(rc=$rc output='$output')"

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
