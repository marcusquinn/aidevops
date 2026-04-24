#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reusable-workflow-caller.sh — Structural tests for the reusable workflow pattern (t2770)
#
# Issues: GH#20662 (issue-sync), GH#20727 (review-bot-gate)
#
# Scenarios covered (issue-sync — tests 1-8):
#   1. .github/workflows/issue-sync-reusable.yml exists and is valid YAML
#   2. Reusable workflow declares `on: workflow_call:` with expected inputs/secrets
#   3. .github/workflows/issue-sync.yml is a thin caller (uses: ./.github/workflows/...)
#   4. .agents/templates/workflows/issue-sync-caller.yml exists
#   5. Downstream caller template references marcusquinn/aidevops reusable path
#   6. Event guards in the reusable workflow accept both pull_request and pull_request_target
#   7. Every checkout of the caller repo is paired with a checkout of marcusquinn/aidevops
#      into __aidevops/ (so helpers resolve via __aidevops/.agents/scripts/*)
#   8. No residual bare .agents/scripts/ helper invocations in the reusable workflow
#
# Scenarios covered (review-bot-gate — tests 9-14, GH#20727):
#   9.  .github/workflows/review-bot-gate-reusable.yml exists
#  10.  Reusable workflow declares `on: workflow_call:` with aidevops_ref input
#  11.  .github/workflows/review-bot-gate.yml is a thin self-caller
#  12.  .agents/templates/workflows/review-bot-gate-caller.yml exists
#  13.  Downstream caller template references marcusquinn/aidevops reusable path
#  14.  Reusable workflow uses __aidevops/ path (runtime-fetched, no SHA pin)
#
# Strategy: Parse YAML + grep for structural invariants. No network calls, no GitHub API.
# Skips gracefully if python3 / yaml module missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

readonly _T_GREEN='\033[0;32m'
readonly _T_RED='\033[0;31m'
readonly _T_YELLOW='\033[0;33m'
readonly _T_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%bPASS%b %s\n' "$_T_GREEN" "$_T_RESET" "$name"
	return 0
}

_fail() {
	local name="$1"
	local msg="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%bFAIL%b %s\n' "$_T_RED" "$_T_RESET" "$name"
	[[ -n "$msg" ]] && printf '       %s\n' "$msg"
	return 0
}

_skip() {
	local name="$1"
	local msg="${2:-}"
	printf '%bSKIP%b %s' "$_T_YELLOW" "$_T_RESET" "$name"
	[[ -n "$msg" ]] && printf ' (%s)' "$msg"
	printf '\n'
	return 0
}

# ---------------------------------------------------------------------------
# Paths under test
# ---------------------------------------------------------------------------

REUSABLE_WF="$REPO_ROOT/.github/workflows/issue-sync-reusable.yml"
SELF_CALLER_WF="$REPO_ROOT/.github/workflows/issue-sync.yml"
DOWNSTREAM_TEMPLATE="$REPO_ROOT/.agents/templates/workflows/issue-sync-caller.yml"

# ---------------------------------------------------------------------------
# Test 1: Reusable workflow file exists
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]]; then
	_pass "reusable workflow file exists"
else
	_fail "reusable workflow file exists" "missing: $REUSABLE_WF"
fi

# ---------------------------------------------------------------------------
# Test 2: Reusable workflow is valid YAML and declares workflow_call
# ---------------------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
	_skip "reusable workflow YAML parse" "python3 unavailable"
elif ! python3 -c "import yaml" 2>/dev/null; then
	_skip "reusable workflow YAML parse" "pyyaml unavailable"
else
	if [[ ! -f "$REUSABLE_WF" ]]; then
		_skip "reusable workflow YAML parse" "file missing"
	else
		# YAML parses cleanly, `on:` has `workflow_call:` key, inputs include `command`
		parse_result="$(python3 - "$REUSABLE_WF" <<'PYEOF' 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
# YAML parses `on` as the boolean True (PyYAML quirk)
on = doc.get('on') or doc.get(True)
if not isinstance(on, dict):
    print("FAIL: `on:` is not a mapping"); sys.exit(1)
if 'workflow_call' not in on:
    print(f"FAIL: `on:` missing `workflow_call`. Keys: {list(on.keys())}"); sys.exit(1)
wc = on['workflow_call'] or {}
inputs = wc.get('inputs', {}) or {}
if 'command' not in inputs:
    print(f"FAIL: workflow_call.inputs missing `command`. Keys: {list(inputs.keys())}"); sys.exit(1)
print("OK")
PYEOF
)"
		if [[ "$parse_result" == "OK" ]]; then
			_pass "reusable workflow declares workflow_call with command input"
		else
			_fail "reusable workflow declares workflow_call with command input" "$parse_result"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Test 3: Self-caller (aidevops's own issue-sync.yml) uses the local reusable
# ---------------------------------------------------------------------------

if [[ -f "$SELF_CALLER_WF" ]]; then
	if grep -Eq "uses:\s*\./\.github/workflows/issue-sync-reusable\.yml" "$SELF_CALLER_WF"; then
		_pass "self-caller uses local reusable workflow"
	else
		_fail "self-caller uses local reusable workflow" \
			"expected 'uses: ./.github/workflows/issue-sync-reusable.yml' in $SELF_CALLER_WF"
	fi
else
	_fail "self-caller uses local reusable workflow" "missing: $SELF_CALLER_WF"
fi

# ---------------------------------------------------------------------------
# Test 4: Downstream caller template exists
# ---------------------------------------------------------------------------

if [[ -f "$DOWNSTREAM_TEMPLATE" ]]; then
	_pass "downstream caller template exists"
else
	_fail "downstream caller template exists" "missing: $DOWNSTREAM_TEMPLATE"
fi

# ---------------------------------------------------------------------------
# Test 5: Downstream caller references marcusquinn/aidevops reusable path
# ---------------------------------------------------------------------------

if [[ -f "$DOWNSTREAM_TEMPLATE" ]]; then
	if grep -Eq "uses:\s*marcusquinn/aidevops/\.github/workflows/issue-sync-reusable\.yml@" \
		"$DOWNSTREAM_TEMPLATE"; then
		_pass "downstream template references marcusquinn/aidevops reusable path"
	else
		_fail "downstream template references marcusquinn/aidevops reusable path" \
			"expected 'uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@<ref>' in $DOWNSTREAM_TEMPLATE"
	fi

	# Also check secrets: inherit (otherwise SYNC_PAT won't propagate)
	if grep -Eq "secrets:\s*inherit" "$DOWNSTREAM_TEMPLATE"; then
		_pass "downstream template uses 'secrets: inherit'"
	else
		_fail "downstream template uses 'secrets: inherit'" \
			"missing 'secrets: inherit' — SYNC_PAT won't reach the reusable workflow"
	fi
fi

# ---------------------------------------------------------------------------
# Test 6: Event guards in reusable workflow accept both pull_request variants
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]]; then
	# Guards that reference only pull_request_target would break downstream
	# callers that chose pull_request for their security model.
	bare_pr_target_count=$(grep -cE "github\.event_name\s*==\s*'pull_request_target'(\s|$)" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$bare_pr_target_count" =~ ^[0-9]+$ ]] || bare_pr_target_count=0
	compound_guard_count=$(grep -cE "(github\.event_name\s*==\s*'pull_request_target'\s*\|\|\s*github\.event_name\s*==\s*'pull_request')|(github\.event_name\s*==\s*'pull_request'\s*\|\|\s*github\.event_name\s*==\s*'pull_request_target')" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$compound_guard_count" =~ ^[0-9]+$ ]] || compound_guard_count=0

	# The compound form is what we want. A bare pull_request_target guard without
	# the compound form is a regression (downstream pull_request callers would skip).
	# We allow bare mentions inside comments/docstrings by requiring the condition
	# guards (if:) to use the compound form.
	if_guard_bare=$(grep -cE "^\s*if:.*github\.event_name\s*==\s*'pull_request_target'" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$if_guard_bare" =~ ^[0-9]+$ ]] || if_guard_bare=0
	if_guard_compound=$(grep -cE "^\s*if:.*github\.event_name\s*==\s*'pull_request_target'.*\|\|.*github\.event_name\s*==\s*'pull_request'" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$if_guard_compound" =~ ^[0-9]+$ ]] || if_guard_compound=0

	if (( if_guard_bare == if_guard_compound )); then
		_pass "all pull_request_target guards include pull_request fallback"
	else
		_fail "all pull_request_target guards include pull_request fallback" \
			"bare guards=$if_guard_bare, compound guards=$if_guard_compound in $REUSABLE_WF"
	fi
fi

# ---------------------------------------------------------------------------
# Test 7: Framework-script paths use __aidevops/ prefix (runtime-fetched)
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]]; then
	# Count references to .agents/scripts/ that are NOT preceded by __aidevops/
	# (allow references in comments/paths-filter lists — restrict to `bash` / `run:` invocations)
	stray=$(grep -nE "(bash|run:)\s+\.agents/scripts/" "$REUSABLE_WF" 2>/dev/null || true)
	if [[ -z "$stray" ]]; then
		_pass "no bare .agents/scripts/ invocations (runtime-fetched via __aidevops/)"
	else
		_fail "no bare .agents/scripts/ invocations" "found:
$stray"
	fi

	# Sanity: at least one __aidevops/.agents/scripts/ invocation should exist
	aidevops_refs=$(grep -cE "__aidevops/\.agents/scripts/" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$aidevops_refs" =~ ^[0-9]+$ ]] || aidevops_refs=0
	if (( aidevops_refs > 0 )); then
		_pass "reusable workflow invokes framework scripts via __aidevops/ ($aidevops_refs references)"
	else
		_fail "reusable workflow invokes framework scripts via __aidevops/" \
			"no __aidevops/.agents/scripts/ references found"
	fi
fi

# ---------------------------------------------------------------------------
# Test 8: Every caller-checkout is paired with a framework checkout
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]] && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
	pairing_result="$(python3 - "$REUSABLE_WF" <<'PYEOF' 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {}) or {}
bad = []
for jname, jdef in jobs.items():
    if not isinstance(jdef, dict):
        continue
    steps = jdef.get('steps', []) or []
    # Find checkouts
    co_steps = []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        uses = step.get('uses', '') or ''
        if uses.startswith('actions/checkout@'):
            with_ = step.get('with', {}) or {}
            repo = (with_.get('repository') or '').strip()
            path = (with_.get('path') or '').strip()
            co_steps.append((i, repo, path))
    # Jobs that do any work with framework scripts must have at least one
    # framework checkout (repository: marcusquinn/aidevops, path: __aidevops)
    job_yaml = yaml.safe_dump(jdef)
    needs_framework = '__aidevops/.agents/scripts/' in job_yaml
    if not needs_framework:
        continue
    has_framework_checkout = any(
        (r == 'marcusquinn/aidevops' and p == '__aidevops')
        for (_, r, p) in co_steps
    )
    if not has_framework_checkout:
        bad.append(jname)
if bad:
    print(f"FAIL: jobs use __aidevops/ but lack framework checkout: {bad}")
    sys.exit(1)
print("OK")
PYEOF
)"
	if [[ "$pairing_result" == "OK" ]]; then
		_pass "every job using framework scripts checks out marcusquinn/aidevops into __aidevops/"
	else
		_fail "every job using framework scripts checks out marcusquinn/aidevops into __aidevops/" \
			"$pairing_result"
	fi
else
	_skip "framework-checkout pairing" "yaml unavailable"
fi

# ---------------------------------------------------------------------------
# review-bot-gate tests (GH#20727)
# ---------------------------------------------------------------------------

RBG_REUSABLE_WF="$REPO_ROOT/.github/workflows/review-bot-gate-reusable.yml"
RBG_SELF_CALLER_WF="$REPO_ROOT/.github/workflows/review-bot-gate.yml"
RBG_DOWNSTREAM_TEMPLATE="$REPO_ROOT/.agents/templates/workflows/review-bot-gate-caller.yml"

# ---------------------------------------------------------------------------
# Test 9: Reusable review-bot-gate workflow file exists
# ---------------------------------------------------------------------------

if [[ -f "$RBG_REUSABLE_WF" ]]; then
	_pass "review-bot-gate reusable workflow file exists"
else
	_fail "review-bot-gate reusable workflow file exists" "missing: $RBG_REUSABLE_WF"
fi

# ---------------------------------------------------------------------------
# Test 10: Reusable review-bot-gate workflow declares workflow_call with aidevops_ref input
# ---------------------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
	_skip "review-bot-gate reusable workflow YAML parse" "python3 unavailable"
elif ! python3 -c "import yaml" 2>/dev/null; then
	_skip "review-bot-gate reusable workflow YAML parse" "pyyaml unavailable"
else
	if [[ ! -f "$RBG_REUSABLE_WF" ]]; then
		_skip "review-bot-gate reusable workflow YAML parse" "file missing"
	else
		parse_result="$(python3 - "$RBG_REUSABLE_WF" <<'PYEOF' 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
on = doc.get('on') or doc.get(True)
if not isinstance(on, dict):
    print("FAIL: `on:` is not a mapping"); sys.exit(1)
if 'workflow_call' not in on:
    print(f"FAIL: `on:` missing `workflow_call`. Keys: {list(on.keys())}"); sys.exit(1)
wc = on['workflow_call'] or {}
inputs = wc.get('inputs', {}) or {}
if 'aidevops_ref' not in inputs:
    print(f"FAIL: workflow_call.inputs missing `aidevops_ref`. Keys: {list(inputs.keys())}"); sys.exit(1)
print("OK")
PYEOF
)"
		if [[ "$parse_result" == "OK" ]]; then
			_pass "review-bot-gate reusable workflow declares workflow_call with aidevops_ref input"
		else
			_fail "review-bot-gate reusable workflow declares workflow_call with aidevops_ref input" "$parse_result"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Test 11: Self-caller (aidevops's own review-bot-gate.yml) uses local reusable
# ---------------------------------------------------------------------------

if [[ -f "$RBG_SELF_CALLER_WF" ]]; then
	if grep -Eq "uses:\s*\./\.github/workflows/review-bot-gate-reusable\.yml" "$RBG_SELF_CALLER_WF"; then
		_pass "review-bot-gate self-caller uses local reusable workflow"
	else
		_fail "review-bot-gate self-caller uses local reusable workflow" \
			"expected 'uses: ./.github/workflows/review-bot-gate-reusable.yml' in $RBG_SELF_CALLER_WF"
	fi
else
	_fail "review-bot-gate self-caller uses local reusable workflow" "missing: $RBG_SELF_CALLER_WF"
fi

# ---------------------------------------------------------------------------
# Test 12: Downstream caller template exists
# ---------------------------------------------------------------------------

if [[ -f "$RBG_DOWNSTREAM_TEMPLATE" ]]; then
	_pass "review-bot-gate downstream caller template exists"
else
	_fail "review-bot-gate downstream caller template exists" "missing: $RBG_DOWNSTREAM_TEMPLATE"
fi

# ---------------------------------------------------------------------------
# Test 13: Downstream caller references marcusquinn/aidevops reusable path and uses secrets: inherit
# ---------------------------------------------------------------------------

if [[ -f "$RBG_DOWNSTREAM_TEMPLATE" ]]; then
	if grep -Eq "uses:\s*marcusquinn/aidevops/\.github/workflows/review-bot-gate-reusable\.yml@" \
		"$RBG_DOWNSTREAM_TEMPLATE"; then
		_pass "review-bot-gate downstream template references marcusquinn/aidevops reusable path"
	else
		_fail "review-bot-gate downstream template references marcusquinn/aidevops reusable path" \
			"expected 'uses: marcusquinn/aidevops/.github/workflows/review-bot-gate-reusable.yml@<ref>' in $RBG_DOWNSTREAM_TEMPLATE"
	fi

	if grep -Eq "secrets:\s*inherit" "$RBG_DOWNSTREAM_TEMPLATE"; then
		_pass "review-bot-gate downstream template uses 'secrets: inherit'"
	else
		_fail "review-bot-gate downstream template uses 'secrets: inherit'" \
			"missing 'secrets: inherit' in $RBG_DOWNSTREAM_TEMPLATE"
	fi
fi

# ---------------------------------------------------------------------------
# Test 14: Reusable review-bot-gate workflow uses __aidevops/ (no SHA pin)
# ---------------------------------------------------------------------------

if [[ -f "$RBG_REUSABLE_WF" ]]; then
	# The old pattern hard-pinned a SHA and used path: .aidevops-helper
	# GH#20727 fix: runtime-fetched into __aidevops/ using inputs.aidevops_ref
	if grep -qE "path:\s*__aidevops" "$RBG_REUSABLE_WF"; then
		_pass "review-bot-gate reusable workflow fetches helper into __aidevops/"
	else
		_fail "review-bot-gate reusable workflow fetches helper into __aidevops/" \
			"expected 'path: __aidevops' in the checkout step — GH#20727 pattern not applied"
	fi

	# Confirm no SHA pin on the aidevops checkout (ref uses inputs.aidevops_ref)
	if grep -qE "ref:\s*\\\$\{\{[[:space:]]*inputs\.aidevops_ref" "$RBG_REUSABLE_WF"; then
		_pass "review-bot-gate reusable workflow uses inputs.aidevops_ref (not a hard-coded SHA)"
	else
		_fail "review-bot-gate reusable workflow uses inputs.aidevops_ref" \
			"expected 'ref: \${{ inputs.aidevops_ref ... }}' — SHA pin not eliminated"
	fi

	# Helper path must not reference .aidevops-helper/ in functional (non-comment) lines.
	# Comments mentioning the old path for historical context are allowed.
	if grep -v "^\s*#" "$RBG_REUSABLE_WF" | grep -q ".aidevops-helper"; then
		_fail "review-bot-gate reusable workflow has no functional .aidevops-helper/ reference" \
			"found stale .aidevops-helper/ path in non-comment line — GH#20727 migration incomplete"
	else
		_pass "review-bot-gate reusable workflow has no functional .aidevops-helper/ reference"
	fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
if (( TESTS_FAILED == 0 )); then
	printf '%bAll %d test(s) passed%b\n' "$_T_GREEN" "$TESTS_RUN" "$_T_RESET"
	exit 0
else
	printf '%b%d of %d test(s) failed%b\n' "$_T_RED" "$TESTS_FAILED" "$TESTS_RUN" "$_T_RESET"
	exit 1
fi
