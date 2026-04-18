#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-opus-47-cascade.sh — opus-4.7 cascade + label-override tests (t2239).
#
# Covers:
#   1. resolve_dispatch_model_for_labels honours model:opus-4-7 override.
#   2. Label override takes precedence over tier:* labels (tier + override → 4.7).
#   3. Tier-only labels continue to resolve via the existing tier path
#      (tier:thinking → opus-4.6 unchanged).
#   4. escalate_issue_tier on tier:thinking without the override adds
#      model:opus-4-7 and keeps tier:thinking (cascade step).
#   5. escalate_issue_tier on tier:thinking WITH the override returns 0
#      with no label mutation (terminal — hand off to NMR).
#
# The cascade is the mechanism wired in worker-lifecycle-common.sh:
#   tier:simple → tier:standard → tier:thinking (opus-4.6)
#   → tier:thinking + model:opus-4-7 (opus-4.7) → NMR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AGENTS_SCRIPTS="$REPO_ROOT/.agents/scripts"

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

# ----- sandbox: stub gh + model-availability-helper -----
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# Stub gh — same shape as test-tier-label-ratchet.sh:
#   - `gh issue view ... --json labels ...` returns CURRENT_LABELS
#   - `gh issue view ... --json body ...` returns ISSUE_BODY
#   - `gh issue edit` appends to GH_EDIT_TRACE
#   - `gh label create` and `gh issue comment` silently succeed.
cat >"$sandbox/gh" <<'STUB'
#!/usr/bin/env bash
args=("$@")

if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "view" ]]; then
	# Inspect the --jq argument to decide which field is being asked for.
	# We don't parse real JSON here — the stub just returns whatever the
	# test wants for that query.
	for ((i = 0; i < ${#args[@]}; i++)); do
		if [[ "${args[i]}" == "--jq" ]]; then
			jq_expr="${args[i + 1]:-}"
			case "$jq_expr" in
			*labels*) printf '%s' "${CURRENT_LABELS:-}"; exit 0 ;;
			*body*)   printf '%s' "${ISSUE_BODY:-}";    exit 0 ;;
			esac
		fi
	done
	printf '%s' "${CURRENT_LABELS:-}"
	exit 0
fi

if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "edit" ]]; then
	printf '%s\n' "${args[*]}" >>"${GH_EDIT_TRACE:-/dev/null}"
	exit 0
fi

if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "comment" ]]; then
	exit 0
fi

if [[ "${args[0]:-}" == "label" && "${args[1]:-}" == "create" ]]; then
	exit 0
fi

exit 0
STUB
chmod +x "$sandbox/gh"

# Stub model-availability-helper.sh — return deterministic model IDs so the
# tier tests don't depend on OAuth pool / API state. Only `resolve` with
# `--quiet` is used by pulse-model-routing.sh.
cat >"$sandbox/model-availability-helper.sh" <<'HELPER'
#!/usr/bin/env bash
# Stub: mirrors the real tier → model mapping for test assertions.
if [[ "${1:-}" == "resolve" ]]; then
	case "${2:-}" in
	opus)   printf '%s' "anthropic/claude-opus-4-6" ;;
	sonnet) printf '%s' "anthropic/claude-sonnet-4-6" ;;
	haiku)  printf '%s' "anthropic/claude-haiku-4-5" ;;
	*)      printf '%s' "" ;;
	esac
	exit 0
fi
exit 1
HELPER
chmod +x "$sandbox/model-availability-helper.sh"

export PATH="$sandbox:$PATH"
export MODEL_AVAILABILITY_HELPER="$sandbox/model-availability-helper.sh"

# ========================================================================
# Part 1 — resolve_dispatch_model_for_labels
# ========================================================================
echo ""
echo "== resolve_dispatch_model_for_labels (label override + tier fallback) =="

# Source pulse-model-routing.sh. It has an include guard so we can source
# in a subshell or fresh shell. Note: the header says it "MUST NOT be
# executed directly" — that refers to `bash pulse-model-routing.sh`,
# which would miss the orchestrator-provided constants. Sourcing in a
# script that has set MODEL_AVAILABILITY_HELPER is the supported pattern.
# shellcheck source=/dev/null
source "$AGENTS_SCRIPTS/pulse-model-routing.sh"

# 1a — model:opus-4-7 alone resolves directly
actual=$(resolve_dispatch_model_for_labels "model:opus-4-7")
assert_equals "anthropic/claude-opus-4-7" "$actual" \
	"label alone: model:opus-4-7 → anthropic/claude-opus-4-7"

# 1b — model:opus-4-7 override wins over tier:standard
actual=$(resolve_dispatch_model_for_labels "tier:standard,model:opus-4-7")
assert_equals "anthropic/claude-opus-4-7" "$actual" \
	"override wins: tier:standard + model:opus-4-7 → anthropic/claude-opus-4-7"

# 1c — model:opus-4-7 override wins over tier:thinking (cascade terminal state)
actual=$(resolve_dispatch_model_for_labels "tier:thinking,model:opus-4-7")
assert_equals "anthropic/claude-opus-4-7" "$actual" \
	"override wins: tier:thinking + model:opus-4-7 → anthropic/claude-opus-4-7"

# 1d — no override, tier:thinking still resolves to opus-4.6 (unchanged default)
actual=$(resolve_dispatch_model_for_labels "tier:thinking")
assert_equals "anthropic/claude-opus-4-6" "$actual" \
	"tier-only: tier:thinking → anthropic/claude-opus-4-6 (default unchanged)"

# 1e — tier:standard resolves to sonnet unchanged
actual=$(resolve_dispatch_model_for_labels "tier:standard")
assert_equals "anthropic/claude-sonnet-4-6" "$actual" \
	"tier-only: tier:standard → anthropic/claude-sonnet-4-6 (unchanged)"

# 1f — tier:simple resolves to haiku unchanged
actual=$(resolve_dispatch_model_for_labels "tier:simple")
assert_equals "anthropic/claude-haiku-4-5" "$actual" \
	"tier-only: tier:simple → anthropic/claude-haiku-4-5 (unchanged)"

# 1g — no labels: empty (caller decides fallback)
actual=$(resolve_dispatch_model_for_labels "")
assert_equals "" "$actual" \
	"no labels: empty result (preserves existing caller-fallback behaviour)"

# 1h — label order independence: override wins whether first or last
actual=$(resolve_dispatch_model_for_labels "model:opus-4-7,tier:thinking,enhancement")
assert_equals "anthropic/claude-opus-4-7" "$actual" \
	"order-independent: override wins when listed first"

actual=$(resolve_dispatch_model_for_labels "enhancement,bug,model:opus-4-7")
assert_equals "anthropic/claude-opus-4-7" "$actual" \
	"order-independent: override wins when listed last"

# ========================================================================
# Part 2 — escalate_issue_tier cascade extension
# ========================================================================
echo ""
echo "== escalate_issue_tier (tier:thinking → model:opus-4-7 → NMR) =="

# Source worker-lifecycle-common.sh to bring escalate_issue_tier into scope.
# It has its own include guard, but the file defines ESCALATION_FAILURE_THRESHOLD
# etc. at source-time so we get the defaults (2 and 1).
# shellcheck source=/dev/null
source "$AGENTS_SCRIPTS/worker-lifecycle-common.sh"

# Helper: run escalate_issue_tier with controlled inputs, return the edit trace.
# We use crash_type="no_work" to bypass the body-quality gate — that gate
# isn't what this test is covering, and the "no_work" path is documented
# in the function header as the intended skip for infra failures.
run_escalate() {
	local current_labels="$1" failure_count="${2:-2}"
	local trace
	trace=$(mktemp)
	GH_EDIT_TRACE="$trace" CURRENT_LABELS="$current_labels" ISSUE_BODY="stub body" \
		escalate_issue_tier 99 "test/repo" "$failure_count" "repeated_failure" "no_work" \
		>/dev/null 2>&1 || true
	cat "$trace"
	rm -f "$trace"
}

# 2a — Cascade step: tier:thinking alone at threshold → add model:opus-4-7
# (keep tier:thinking; the override takes precedence on next dispatch)
trace=$(run_escalate "tier:thinking" 2)
assert_contains "$trace" "--add-label model:opus-4-7" \
	"cascade: tier:thinking @ threshold → adds model:opus-4-7 label"
assert_not_contains "$trace" "--remove-label tier:thinking" \
	"cascade: tier:thinking preserved for history (not removed)"

# 2b — Terminal: tier:thinking + model:opus-4-7 at threshold → no mutation
# (escalate_issue_tier returns 0 early; no gh issue edit recorded)
trace=$(run_escalate "tier:thinking,model:opus-4-7" 2)
assert_equals "" "$trace" \
	"terminal: tier:thinking + model:opus-4-7 → no label mutation (hand off to NMR)"

# 2c — Order-independent: model:opus-4-7 listed first before tier:thinking
trace=$(run_escalate "model:opus-4-7,tier:thinking" 2)
assert_equals "" "$trace" \
	"terminal: order-independent (override first) → no mutation"

# 2d — Unchanged: tier:standard at threshold still escalates to tier:thinking
# (confirms the new branch did not break the existing cascade rungs below)
trace=$(run_escalate "tier:standard" 2)
assert_contains "$trace" "--add-label tier:thinking" \
	"unchanged: tier:standard @ threshold → adds tier:thinking (existing cascade)"
assert_contains "$trace" "--remove-label tier:standard" \
	"unchanged: tier:standard @ threshold → removes tier:standard"
assert_not_contains "$trace" "model:opus-4-7" \
	"unchanged: tier:standard cascade does NOT add model:opus-4-7 (that's the next rung up)"

# 2e — Unchanged: tier:simple → tier:standard (existing cascade preserved)
trace=$(run_escalate "tier:simple" 2)
assert_contains "$trace" "--add-label tier:standard" \
	"unchanged: tier:simple @ threshold → adds tier:standard (existing cascade)"
assert_contains "$trace" "--remove-label tier:simple" \
	"unchanged: tier:simple @ threshold → removes tier:simple"

# 2f — Threshold guard: sub-threshold failures do not escalate
trace=$(run_escalate "tier:thinking" 1)
assert_equals "" "$trace" \
	"threshold guard: failure_count < threshold → no escalation"

# ========================================================================
# Summary
# ========================================================================
echo ""
echo "Tests passed: $tests_passed / $tests_run"

if [[ $tests_passed -eq $tests_run ]]; then
	exit 0
fi
exit 1
