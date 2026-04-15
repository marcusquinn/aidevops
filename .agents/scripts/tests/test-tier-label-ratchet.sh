#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-tier-label-ratchet.sh — tests for _tier_rank and _apply_tier_label_replace
# ratchet rule (t2111, GH#19070).
#
# The ratchet rule guards enrichment from reverting a cascade-escalated tier
# label. Without it, `issue-sync` on its next scheduled run would read the
# brief's `**Selected tier:**` line and strip any higher tier label that
# `escalate_issue_tier()` in worker-lifecycle-common.sh previously applied —
# producing the tier:standard -> tier:thinking -> tier:standard flip-flop
# observed on GH#19038.
#
# The integration tests below stub `gh` via PATH prefix so we can assert on
# the sequence of edit args without making real API calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source the helper to get _tier_rank and _apply_tier_label_replace.
# The main() at the bottom of issue-sync-helper.sh is guarded by a
# BASH_SOURCE == $0 check (t2063), so sourcing is safe.
# shellcheck source=/dev/null
source "$REPO_ROOT/.agents/scripts/issue-sync-helper.sh"

# ----- test harness -----
tests_run=0
tests_passed=0

assert_equals() {
	local expected="$1" actual="$2" name="$3"
	tests_run=$((tests_run + 1))
	if [[ "$expected" == "$actual" ]]; then
		tests_passed=$((tests_passed + 1))
		echo "PASS: $name"
		return 0
	fi
	echo "FAIL: $name"
	echo "  expected: $expected"
	echo "  actual:   $actual"
	return 1
}

assert_not_contains() {
	local haystack="$1" needle="$2" name="$3"
	tests_run=$((tests_run + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		tests_passed=$((tests_passed + 1))
		echo "PASS: $name"
		return 0
	fi
	echo "FAIL: $name"
	echo "  haystack: $haystack"
	echo "  unwanted: $needle"
	return 1
}

assert_contains() {
	local haystack="$1" needle="$2" name="$3"
	tests_run=$((tests_run + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		tests_passed=$((tests_passed + 1))
		echo "PASS: $name"
		return 0
	fi
	echo "FAIL: $name"
	echo "  haystack: $haystack"
	echo "  missing:  $needle"
	return 1
}

# ========================================================================
# Part 1 — _tier_rank unit tests
# ========================================================================
echo ""
echo "== _tier_rank =="

assert_equals "0" "$(_tier_rank tier:simple)" "_tier_rank tier:simple -> 0"
assert_equals "1" "$(_tier_rank tier:standard)" "_tier_rank tier:standard -> 1"
assert_equals "2" "$(_tier_rank tier:thinking)" "_tier_rank tier:thinking -> 2"
assert_equals "-1" "$(_tier_rank '')" "_tier_rank empty -> -1"
assert_equals "-1" "$(_tier_rank tier:bogus)" "_tier_rank unknown -> -1"
assert_equals "-1" "$(_tier_rank bug)" "_tier_rank non-tier label -> -1"

# ========================================================================
# Part 2 — _apply_tier_label_replace ratchet behaviour (stubbed gh)
# ========================================================================
echo ""
echo "== _apply_tier_label_replace ratchet =="

# Create a sandbox where we prepend a fake `gh` to PATH. The fake gh:
#   - reads CURRENT_TIERS from the env to answer `gh issue view ... labels`
#   - logs every `gh issue edit` invocation to GH_TRACE_FILE
#   - ignores `gh label create --force` (used elsewhere in the helper)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

cat >"$sandbox/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub for test-tier-label-ratchet.sh
args=("$@")

# `gh issue view <num> --repo <slug> --json labels --jq '...'`
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "view" ]]; then
	# CURRENT_TIERS is a comma-separated list of tier:* labels the issue
	# currently carries. Emit JSON that the --jq expression in the caller
	# will reduce to the same comma-joined list.
	printf '%s' "${CURRENT_TIERS:-}"
	exit 0
fi

# `gh issue edit <num> --repo <slug> [--add-label X] [--remove-label Y] ...`
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "edit" ]]; then
	printf '%s\n' "${args[*]}" >>"${GH_TRACE_FILE:-/dev/null}"
	exit 0
fi

# `gh label create ... --force` — used by escalate path, not by replace.
if [[ "${args[0]:-}" == "label" && "${args[1]:-}" == "create" ]]; then
	exit 0
fi

# Anything else: silently succeed so we don't have to stub the whole surface.
exit 0
STUB
chmod +x "$sandbox/gh"
export PATH="$sandbox:$PATH"

run_replace() {
	# run_replace <existing_tiers_csv> <new_tier>
	# Returns: content of the GH edit trace file on stdout (possibly empty).
	local existing="$1" new="$2"
	local trace
	trace=$(mktemp)
	GH_TRACE_FILE="$trace" CURRENT_TIERS="$existing" \
		_apply_tier_label_replace test/repo 1 "$new" >/dev/null 2>&1 || true
	cat "$trace"
	rm -f "$trace"
}

# Case 1 — THE #19038 FLIP-FLOP CASE
# Existing tier:thinking (cascade-escalated), incoming tier:standard (brief).
# Must be a NO-OP: no `--remove-label tier:thinking` in the trace.
trace=$(run_replace "tier:thinking" "tier:standard")
assert_not_contains "$trace" "--remove-label tier:thinking" \
	"ratchet: preserves tier:thinking when incoming tier:standard (GH#19038)"
assert_not_contains "$trace" "--add-label tier:standard" \
	"ratchet: does not add tier:standard over existing tier:thinking"

# Case 2 — symmetric case: existing tier:standard, incoming tier:simple -> no-op
trace=$(run_replace "tier:standard" "tier:simple")
assert_not_contains "$trace" "--remove-label tier:standard" \
	"ratchet: preserves tier:standard when incoming tier:simple"
assert_not_contains "$trace" "--add-label tier:simple" \
	"ratchet: does not add tier:simple over existing tier:standard"

# Case 3 — existing tier:thinking, incoming tier:simple -> no-op
trace=$(run_replace "tier:thinking" "tier:simple")
assert_not_contains "$trace" "--remove-label tier:thinking" \
	"ratchet: preserves tier:thinking when incoming tier:simple"

# Case 4 — multi-tier collision: existing tier:simple + tier:thinking,
# incoming tier:standard. Max rank 2 > incoming 1, so NO-OP even though
# the lower tier:simple "should" be replaced in isolation.
trace=$(run_replace "tier:simple,tier:thinking" "tier:standard")
assert_not_contains "$trace" "--remove-label tier:thinking" \
	"ratchet: multi-tier preserves tier:thinking when max > incoming"
assert_not_contains "$trace" "--remove-label tier:simple" \
	"ratchet: multi-tier no-ops entirely (does not partial-clean)"

# ----- negative tests (pre-existing behaviour MUST NOT regress) -----

# Case 5 — upgrade: existing tier:simple, incoming tier:standard -> replace
trace=$(run_replace "tier:simple" "tier:standard")
assert_contains "$trace" "--remove-label tier:simple" \
	"upgrade: removes tier:simple when incoming tier:standard"
assert_contains "$trace" "--add-label tier:standard" \
	"upgrade: adds tier:standard when incoming outranks existing"

# Case 6 — upgrade: existing tier:standard, incoming tier:thinking -> replace
trace=$(run_replace "tier:standard" "tier:thinking")
assert_contains "$trace" "--remove-label tier:standard" \
	"upgrade: removes tier:standard when incoming tier:thinking"
assert_contains "$trace" "--add-label tier:thinking" \
	"upgrade: adds tier:thinking when incoming outranks existing"

# Case 7 — upgrade through multi-tier: existing simple+standard, incoming thinking
trace=$(run_replace "tier:simple,tier:standard" "tier:thinking")
assert_contains "$trace" "--remove-label tier:simple" \
	"upgrade multi: removes tier:simple when incoming tier:thinking"
assert_contains "$trace" "--remove-label tier:standard" \
	"upgrade multi: removes tier:standard when incoming tier:thinking"
assert_contains "$trace" "--add-label tier:thinking" \
	"upgrade multi: adds tier:thinking"

# Case 8 — empty existing: bootstrap from no tier -> replace path runs
trace=$(run_replace "" "tier:standard")
assert_contains "$trace" "--add-label tier:standard" \
	"bootstrap: adds tier:standard when no existing tier label"

# Case 9 — equal rank: existing tier:standard, incoming tier:standard -> no regression
# (should still add-label tier:standard, idempotent per existing behaviour)
trace=$(run_replace "tier:standard" "tier:standard")
assert_contains "$trace" "--add-label tier:standard" \
	"equal: idempotent add when existing rank == incoming rank"
assert_not_contains "$trace" "--remove-label tier:standard" \
	"equal: does not remove matching tier label"

# ========================================================================
# Summary
# ========================================================================
echo ""
echo "Tests passed: $tests_passed / $tests_run"

if [[ $tests_passed -eq $tests_run ]]; then
	exit 0
fi
exit 1
