#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-dedup-cost-interactive-filter.sh — t2425 / GH#20047 regression guard.
#
# Asserts that _sum_issue_token_spend in dispatch-dedup-cost.sh filters out
# comments whose signature footer indicates an interactive session. Without
# this filter, maintainer triage/review comments (which always carry an
# interactive-session footer from gh-signature-helper.sh) inflate the
# per-issue aggregator toward the tier budget and trip the circuit breaker
# on otherwise-dispatchable issues. Observed failure: GH#20004 / GH#20014 /
# GH#20021 each read 1.6M+ tokens, virtually all from maintainer interactive
# footers, while real worker spend was zero or well under tier budget.
#
# Canonical footer markers emitted by gh-signature-helper.sh (~lines 1154-1156):
#   - Worker:      "...as a headless worker."
#   - Interactive: "...with the user in an interactive session."
#
# Filter semantics — invert, fail-open:
#   * Comments containing "with the user in an interactive session" are excluded.
#   * Comments without either marker (historical or non-standard footers) are
#     KEPT — worker is the safer default, matching the aggregator's existing
#     fail-open posture on unrecognised inputs.
#
# Model on test-cost-circuit-breaker.sh (t2007) — same stub-gh harness with
# a swappable comments fixture, driven via the sum-issue-token-spend CLI.

# Negative assertions benefit from explicit exit-code capture — no `set -e`.
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
	return 0
}

# Sandbox HOME so any side-effect writes are isolated.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Stub harness — fake `gh` CLI that returns a canned comments fixture.
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
FIXTURE_COMMENTS_JSON="${TEST_ROOT}/fixture-comments.json"

cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for test-dispatch-dedup-cost-interactive-filter.sh
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
# Any other gh invocation is silently a no-op in this test's scope.
exit 0
STUB
chmod +x "${STUB_DIR}/gh"

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Build a comments JSON fixture. Each argument is a "<kind>|<tokens>" pair
# where <kind> is "worker", "interactive", or "nomarker". The footer prose
# mirrors the shape emitted by gh-signature-helper.sh (the filter keys on
# the literal "with the user in an interactive session" substring).
write_mixed_comments() {
	local first=1
	local item kind tokens body
	local json=""
	for item in "$@"; do
		kind="${item%%|*}"
		tokens="${item#*|}"
		case "$kind" in
		worker)
			body="Worker run.\\n\\n<!-- aidevops:sig -->\\n---\\n[aidevops.sh](https://aidevops.sh) v3.8.78 plugin for [OpenCode](https://opencode.ai) v1.14.18 with claude-sonnet-4-6 spent 4m and ${tokens} tokens on this as a headless worker."
			;;
		interactive)
			body="Maintainer triage comment.\\n\\n<!-- aidevops:sig -->\\n---\\n[aidevops.sh](https://aidevops.sh) v3.8.78 plugin for [OpenCode](https://opencode.ai) v1.14.18 with claude-opus-4-7 spent 1h 20m and ${tokens} tokens on this with the user in an interactive session."
			;;
		nomarker)
			# Historical wording: no "as a headless worker" / no "interactive session" marker.
			body="Legacy worker comment.\\n---\\nclaude-sonnet-4-5 spent ${tokens} tokens on this."
			;;
		*)
			echo "bad fixture kind: ${kind}" >&2
			return 1
			;;
		esac
		if [[ "$first" -eq 0 ]]; then
			json+=","
		fi
		first=0
		json+="{\"body\":\"${body}\"}"
	done
	printf '[%s]' "$json" >"$FIXTURE_COMMENTS_JSON"
	return 0
}

run_sum() {
	local issue="$1" repo="${2:-owner/repo}"
	"$DEDUP_HELPER" sum-issue-token-spend "$issue" "$repo" 2>/dev/null
	return 0
}

# =============================================================================
# Assertion 1 — Pure interactive thread → 0|0
# =============================================================================
# Three interactive-session comments of 500,000 tokens each. Real worker
# spend is zero; the aggregator MUST return "0|0" rather than 1,500,000.
# This is the direct reproduction of the GH#20004/20014/20021 failure mode.
write_mixed_comments \
	"interactive|500000" \
	"interactive|500000" \
	"interactive|500000"
out=$(run_sum 20001)
if [[ "$out" == "0|0" ]]; then
	print_result "pure interactive thread excluded (3×500K → 0|0)" 0
else
	print_result "pure interactive thread excluded (3×500K → 0|0)" 1 "(got: '$out')"
fi

# =============================================================================
# Assertion 2 — Mixed interactive + worker → worker-only
# =============================================================================
# One worker comment (50,000 tokens) + two interactive comments (500,000
# each). Expected: 50000|1 — only the worker contribution counts.
write_mixed_comments \
	"interactive|500000" \
	"worker|50000" \
	"interactive|500000"
out=$(run_sum 20002)
if [[ "$out" == "50000|1" ]]; then
	print_result "mixed thread: worker counted, interactives excluded (→ 50000|1)" 0
else
	print_result "mixed thread: worker counted, interactives excluded (→ 50000|1)" 1 "(got: '$out')"
fi

# =============================================================================
# Assertion 3 — Pure worker thread → unchanged behaviour
# =============================================================================
# Two worker comments, 30K and 40K. Expected: 70000|2. Confirms the filter
# does not regress the existing aggregation for genuine worker traffic.
write_mixed_comments \
	"worker|30000" \
	"worker|40000"
out=$(run_sum 20003)
if [[ "$out" == "70000|2" ]]; then
	print_result "pure worker thread unaffected by filter (→ 70000|2)" 0
else
	print_result "pure worker thread unaffected by filter (→ 70000|2)" 1 "(got: '$out')"
fi

# =============================================================================
# Assertion 4 — No-marker fallback → kept (fail-open as worker)
# =============================================================================
# Legacy footer with neither "interactive session" nor "headless worker"
# marker. Expected: 25000|1 — the comment is kept (treated as worker). This
# preserves the function's historical fail-open posture on unrecognised
# footers; they were always counted before this fix and must continue to be.
write_mixed_comments "nomarker|25000"
out=$(run_sum 20004)
if [[ "$out" == "25000|1" ]]; then
	print_result "no-marker footer falls open to worker (→ 25000|1)" 0
else
	print_result "no-marker footer falls open to worker (→ 25000|1)" 1 "(got: '$out')"
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
