#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-large-file-gate-body.sh — t2371 regression guard.
#
# Verifies that scanner-filed issue bodies contain the four enhancements
# required by t2371:
#
#   1. Link to `.agents/reference/large-file-split.md` (the split playbook)
#   2. Citation of `issue-sync-helper.sh` + `issue-sync-lib.sh` as in-repo precedent
#   3. Pre-declaration of `complexity-bump-ok` / `ratchet-bump` label + `Complexity Bump Justification` section
#   4. The `<!-- aidevops:generator=... -->` marker for pre-dispatch validators
#
# Tests all five scanner body templates:
#   Part 1: `pulse-dispatch-large-file-gate.sh` (file-size-debt bodies)
#   Part 2: `stats-quality-sweep-issues.sh` (_build_simplification_issue_body)
#   Part 3: `pulse-simplification-issues.sh` SH body (_complexity_scan_sh_build_issue_body_with_sig)
#   Part 4: `pulse-simplification-issues.sh` MD body (_complexity_scan_build_md_issue_body)
#   Part 5: `pulse-simplification-state.sh` requeue body (_create_requeue_issue)
#
# Cross-references: GH#19828 / t2371, GH#19699 (the too-thin body),
# t2368 (large-file-split.md playbook), t2367 (generator marker).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"
SWEEP_SCRIPT="${SCRIPT_DIR_TEST}/../stats-quality-sweep-issues.sh"
SIMPLIFICATION_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-simplification-issues.sh"
REQUEUE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-simplification-state.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
	local test_name="$1"
	local haystack="$2"
	local needle="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       missing: %s\n' "$needle"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

######################################################################
# Part 1: Large-file gate body (pulse-dispatch-large-file-gate.sh)
#
# The body is constructed inline in _large_file_gate_file_new_debt_issue
# as _create_body. We can't call the function without gh, so we test by
# extracting the body template from source — the template uses shell
# variable interpolation, so we verify the static strings that must appear
# regardless of variable values.
######################################################################

printf '\n=== test-large-file-gate-body.sh (t2371) ===\n\n'
printf '%s\n\n' '--- Part 1: Large-file gate (file-size-debt) body ---'

# Read the gate script body template (the _create_body assignment)
gate_body_section=$(sed -n '/_create_body="/,/^_Created by large-file/p' "$GATE_SCRIPT")

# Test 1.1: Generator marker
assert_contains \
	"large-file: generator marker present" \
	"$gate_body_section" \
	"aidevops:generator=large-file-simplification-gate"

# Test 1.2: Canonical worker scope contract
assert_contains \
	"large-file: canonical Files Scope heading" \
	"$gate_body_section" \
	"### Files Scope"

# shellcheck disable=SC2016 # Literal Markdown scope declaration.
assert_contains \
	"large-file: canonical edit target" \
	"$gate_body_section" \
	'- EDIT: \`${lf_path}\`'

# Test 1.3: Playbook link
assert_contains \
	"large-file: playbook reference" \
	"$gate_body_section" \
	"large-file-split.md"

# Test 1.3: Precedent citation
assert_contains \
	"large-file: issue-sync-helper.sh precedent" \
	"$gate_body_section" \
	"issue-sync-helper.sh"

# Test 1.4: Precedent citation (lib)
assert_contains \
	"large-file: issue-sync-lib.sh precedent" \
	"$gate_body_section" \
	"issue-sync-lib.sh"

# Test 1.5: CI override label
assert_contains \
	"large-file: complexity-bump-ok label mention" \
	"$gate_body_section" \
	"complexity-bump-ok"

# Test 1.6: Justification section requirement
assert_contains \
	"large-file: Complexity Bump Justification section mention" \
	"$gate_body_section" \
	"Complexity Bump Justification"

# Test 1.7: Playbook section reference (Known CI False-Positive Classes)
assert_contains \
	"large-file: playbook section 4 reference" \
	"$gate_body_section" \
	"Known CI False-Positive Classes"

# Test 1.8: headless-runtime-lib.sh complex precedent
assert_contains \
	"large-file: headless-runtime-lib.sh complex precedent" \
	"$gate_body_section" \
	"headless-runtime-lib.sh"

######################################################################
# Part 2: Function-complexity sweep body (stats-quality-sweep.sh)
#
# _build_simplification_issue_body is a pure function that writes to
# stdout. We can source the script and call it directly.
# However, the script sources many pulse dependencies. Instead, we
# extract the function body from the heredoc and test the static
# template strings.
######################################################################

printf '\n%s\n\n' '--- Part 2: Function-complexity sweep body ---'

# Extract the heredoc body from _build_simplification_issue_body
sweep_body_section=$(sed -n '/_build_simplification_issue_body()/,/^BODY$/p' "$SWEEP_SCRIPT")

# Test 2.1: Generator marker
assert_contains \
	"complexity-sweep: generator marker present" \
	"$sweep_body_section" \
	"aidevops:generator=function-complexity-sweep"

# Test 2.2: Playbook link
assert_contains \
	"complexity-sweep: playbook reference" \
	"$sweep_body_section" \
	"large-file-split.md"

# Test 2.3: Precedent citation
assert_contains \
	"complexity-sweep: issue-sync-helper.sh precedent" \
	"$sweep_body_section" \
	"issue-sync-helper.sh"

# Test 2.4: Precedent citation (lib)
assert_contains \
	"complexity-sweep: issue-sync-lib.sh precedent" \
	"$sweep_body_section" \
	"issue-sync-lib.sh"

# Test 2.5: CI override label (ratchet-bump for complexity sweep)
assert_contains \
	"complexity-sweep: ratchet-bump label mention" \
	"$sweep_body_section" \
	"ratchet-bump"

# Test 2.6: Justification section requirement
assert_contains \
	"complexity-sweep: Complexity Bump Justification section mention" \
	"$sweep_body_section" \
	"Complexity Bump Justification"

# Test 2.7: Playbook section reference
assert_contains \
	"complexity-sweep: playbook section 4 reference" \
	"$sweep_body_section" \
	"Known CI False-Positive Classes"

# Test 2.8: headless-runtime-lib.sh complex precedent
assert_contains \
	"complexity-sweep: headless-runtime-lib.sh complex precedent" \
	"$sweep_body_section" \
	"headless-runtime-lib.sh"

# Test 2.9: autonomous brief declares the exact editable path
assert_contains \
	"complexity-sweep: canonical Files Scope heading" \
	"$sweep_body_section" \
	"### Files Scope"
# shellcheck disable=SC2016 # literal generator template expression
assert_contains \
	"complexity-sweep: cited file is editable" \
	"$sweep_body_section" \
	'- EDIT: \`${file_path}\`'

######################################################################
# Part 3: SH complexity scanner body (pulse-simplification.sh)
#
# _complexity_scan_sh_build_issue_body_with_sig builds the body as a
# local variable. Extract the function body from source.
######################################################################

printf '\n%s\n\n' '--- Part 3: SH function-complexity body ---'

sh_body_section=$(sed -n '/_complexity_scan_sh_build_issue_body_with_sig()/,/^}$/p' "$SIMPLIFICATION_SCRIPT")

# Test 3.1: Generator marker
assert_contains \
	"sh-complexity: generator marker present" \
	"$sh_body_section" \
	"aidevops:generator=function-complexity-gate"

# Test 3.2: Playbook link
assert_contains \
	"sh-complexity: playbook reference" \
	"$sh_body_section" \
	"large-file-split.md"

# Test 3.3: Precedent citation
assert_contains \
	"sh-complexity: issue-sync-helper.sh precedent" \
	"$sh_body_section" \
	"issue-sync-helper.sh"

# Test 3.4: CI override label
assert_contains \
	"sh-complexity: complexity-bump-ok label mention" \
	"$sh_body_section" \
	"complexity-bump-ok"

# Test 3.5: Justification section
assert_contains \
	"sh-complexity: Complexity Bump Justification section mention" \
	"$sh_body_section" \
	"Complexity Bump Justification"

# Test 3.6: generated shell brief has an editable canonical scope
assert_contains \
	"sh-complexity: canonical Files Scope heading" \
	"$sh_body_section" \
	"### Files Scope"
# shellcheck disable=SC2016 # literal generator template expression
assert_contains \
	"sh-complexity: cited file is editable" \
	"$sh_body_section" \
	'- EDIT: \`${file_path}\`'

######################################################################
# Part 4: MD agent doc body (pulse-simplification.sh)
#
# _complexity_scan_build_md_issue_body outputs via heredoc.
######################################################################

printf '\n%s\n\n' '--- Part 4: MD agent doc body ---'

md_body_section=$(sed -n '/_complexity_scan_build_md_issue_body()/,/^}$/p' "$SIMPLIFICATION_SCRIPT")

# Test 4.1: Generator marker
assert_contains \
	"md-simplification: generator marker present" \
	"$md_body_section" \
	"aidevops:generator=agent-doc-simplification-gate"

# Test 4.2: Playbook link
assert_contains \
	"md-simplification: playbook reference" \
	"$md_body_section" \
	"large-file-split.md"

# Test 4.3: Precedent citation
assert_contains \
	"md-simplification: issue-sync-helper.sh precedent" \
	"$md_body_section" \
	"issue-sync-helper.sh"

# Test 4.4: CI override label
assert_contains \
	"md-simplification: complexity-bump-ok label mention" \
	"$md_body_section" \
	"complexity-bump-ok"

# Test 4.5: generated Markdown brief has an editable canonical scope
assert_contains \
	"md-simplification: canonical Files Scope heading" \
	"$md_body_section" \
	"### Files Scope"
# shellcheck disable=SC2016 # literal generator template expression
assert_contains \
	"md-simplification: cited file is editable" \
	"$md_body_section" \
	'- EDIT: \`${file_path}\`'

######################################################################
# Part 5: Requeue body (pulse-simplification-state.sh)
#
# _create_requeue_issue calls gh_create_issue. Extract from source.
######################################################################

printf '\n%s\n\n' '--- Part 5: Requeue body ---'

requeue_body_section=$(sed -n '/_create_requeue_issue()/,/^}$/p' "$REQUEUE_SCRIPT")

# Test 5.1: Generator marker
assert_contains \
	"requeue: generator marker present" \
	"$requeue_body_section" \
	"aidevops:generator=function-complexity-gate"

# Test 5.2: Playbook link
assert_contains \
	"requeue: playbook reference" \
	"$requeue_body_section" \
	"large-file-split.md"

# Test 5.3: Precedent citation
assert_contains \
	"requeue: issue-sync-helper.sh precedent" \
	"$requeue_body_section" \
	"issue-sync-helper.sh"

# Test 5.4: CI override label
assert_contains \
	"requeue: complexity-bump-ok label mention" \
	"$requeue_body_section" \
	"complexity-bump-ok"

######################################################################
# Part 6: Reused debt-issue body refresh (GH#37989)
#
# A reused file-size-debt issue whose body predates `### Files Scope`
# fails the pre-dispatch validator forever. The gate rewrites such a body
# to the current template, and leaves every other body alone.
######################################################################

printf '\n%s\n\n' '--- Part 6: Reused debt-issue body refresh (GH#37989) ---'

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected: %q\n' "$expected"
	printf '       actual:   %q\n' "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

REFRESH_TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$REFRESH_TMP"' EXIT
LOGFILE="${REFRESH_TMP}/pulse.log"
LARGE_FILE_LINE_THRESHOLD=2000
: >"$LOGFILE"
# shellcheck source=../pulse-dispatch-large-file-gate.sh
source "$GATE_SCRIPT"

LF_PATH=".agents/scripts/pulse-issue-reconcile.sh"
STUB_ISSUE_JSON=""
STUB_EDIT_RC=0
EDIT_LOG="${REFRESH_TMP}/edits.log"
EDIT_BODY="${REFRESH_TMP}/edit-body.md"
CREATE_BODY="${REFRESH_TMP}/create-body.md"

gh() { return 0; }
sleep() { return 0; }
set_issue_status() { return 0; }
gh_issue_view() {
	printf '%s' "$STUB_ISSUE_JSON"
	return 0
}
gh_issue_edit_safe() {
	local arg="" next_is_file=false
	printf '%s\n' "$*" >>"$EDIT_LOG"
	for arg in "$@"; do
		if [[ "$next_is_file" == true ]]; then
			cp "$arg" "$EDIT_BODY"
			next_is_file=false
		fi
		[[ "$arg" != "--body-file" ]] || next_is_file=true
	done
	return "$STUB_EDIT_RC"
}
gh_create_issue() {
	local prev=""
	local arg=""
	for arg in "$@"; do
		[[ "$prev" != "--body" ]] || printf '%s' "$arg" >"$CREATE_BODY"
		prev="$arg"
	done
	return 0
}

# Build an issue JSON object with the given body and label names.
stub_issue() {
	local body="$1"
	shift
	local labels_json=""
	labels_json=$(printf '%s\n' "$@" | jq -R 'select(length > 0) | {name: .}' | jq -s '.')
	STUB_ISSUE_JSON=$(jq -n --arg body "$body" --argjson labels "$labels_json" \
		'{body: $body, labels: $labels}')
	return 0
}

edit_count() {
	if [[ -f "$EDIT_LOG" ]]; then
		wc -l <"$EDIT_LOG" | tr -d ' '
	else
		printf '0'
	fi
	return 0
}

reset_refresh_state() {
	rm -f "$EDIT_LOG" "$EDIT_BODY" "$CREATE_BODY"
	: >"$LOGFILE"
	STUB_EDIT_RC=0
	return 0
}

# The pre-template body shape the gate wrote at v3.13.0 (EDIT under ## How).
STALE_BODY="<!-- aidevops:generator=large-file-simplification-gate cited_file=${LF_PATH} threshold=2000 -->

## What
Simplify \`${LF_PATH}\` — currently over 2000 lines.

## Why
Issue #21375 is blocked by the large-file gate.

## How
- EDIT: \`${LF_PATH}\`"

# Test 6.1: new-issue body is byte-identical to the pre-change template.
# shellcheck disable=SC2016 # Literal Markdown fixture.
EXPECTED_NEW_BODY=$(
	cat <<'BODY'
<!-- aidevops:generator=large-file-simplification-gate cited_file=.agents/scripts/pulse-issue-reconcile.sh threshold=2000 -->

## What
Simplify `.agents/scripts/pulse-issue-reconcile.sh` — currently over 2000 lines. Break into smaller, focused modules.

## Why
Issue #37939 is blocked by the large-file gate. Workers dispatched against this file spend most of their context budget reading it, leaving insufficient capacity for implementation.

### Files Scope

- EDIT: `.agents/scripts/pulse-issue-reconcile.sh`
- NEW: `.agents/scripts/pulse-issue-reconcile-*.sh`

## How
- Extract cohesive function groups into separate files
- Keep a thin orchestrator in the original file that sources the extracted modules
- Verify: `wc -l .agents/scripts/pulse-issue-reconcile.sh` should be below 2000
- Verify: `python3 ~/.aidevops/agents/scripts/file-split-verify.py --base origin/main --head HEAD` exits 0 (pure move: `removed-only=0 review=0 gated=0`); paste its summary line into the PR body (playbook section 7.5)

**Reference pattern:** `.agents/reference/large-file-split.md` (playbook for file splits — covers identity-key preservation, CI false-positives, and PR body template).

**Precedent in this repo:** `issue-sync-helper.sh` + `issue-sync-lib.sh` (simple split) and `headless-runtime-lib.sh` + sub-libraries (complex split). For shell scripts, copy the include-guard and SCRIPT_DIR-fallback pattern from the simple precedent.

**Expected CI gate overrides:** This PR will likely trigger a complexity regression from the file-split identity-key change. Apply the `complexity-bump-ok` label AND include a `## Complexity Bump Justification` section in the PR body citing scanner evidence. See the playbook section 4 (Known CI False-Positive Classes).

_Created by large-file simplification gate (pulse-dispatch-core.sh)_
BODY
)
reset_refresh_state
_large_file_gate_file_new_debt_issue "$LF_PATH" "37939" "owner/repo" "" >/dev/null
assert_eq \
	"refresh: new-issue body unchanged by builder extraction" \
	"$EXPECTED_NEW_BODY" \
	"$(<"$CREATE_BODY")"

# Test 6.2: scope fallback (validator library unavailable) uses the same rule.
_saved_lfg_dir="$_LFG_SCRIPT_DIR"
_LFG_SCRIPT_DIR="${REFRESH_TMP}/missing"
fallback_rc=0
_large_file_gate_body_has_scope_path "$STALE_BODY" || fallback_rc=$?
assert_eq "refresh: fallback rule rejects a body without a scope" "1" "$fallback_rc"
fallback_rc=0
_large_file_gate_body_has_scope_path "$EXPECTED_NEW_BODY" || fallback_rc=$?
assert_eq "refresh: fallback rule accepts the current template" "0" "$fallback_rc"
_LFG_SCRIPT_DIR="$_saved_lfg_dir"

# Test 6.3: reopening a stale marked body rewrites it, naming the held issue.
reset_refresh_state
stub_issue "$STALE_BODY" "file-size-debt" "auto-dispatch"
out=$(_large_file_gate_reopen_debt_issue "21376" "$LF_PATH" "owner/repo" "37939")
assert_eq "refresh: reopen result unchanged" "#21376 (reopened)" "$out"
assert_eq "refresh: reopen writes one body edit" "1" "$(edit_count)"
assert_contains "refresh: reopen edit targets the debt issue" \
	"$(cat "$EDIT_LOG" 2>/dev/null)" "21376 --repo owner/repo --body-file"
assert_eq "refresh: reopened body is the current template for the held issue" \
	"$(_large_file_gate_debt_issue_body "$LF_PATH" "37939" "")" \
	"$(cat "$EDIT_BODY" 2>/dev/null)"

# Test 6.4: the refreshed body passes the pre-dispatch validator.
_log() { return 0; }
# shellcheck source=../pre-dispatch-validator-lib-brief-scope.sh
source "${SCRIPT_DIR_TEST}/../pre-dispatch-validator-lib-brief-scope.sh"
validator_rc=0
_validate_implementation_brief_scope "21376" "$(cat "$EDIT_BODY" 2>/dev/null)" 1 "file-size-debt,auto-dispatch" || validator_rc=$?
assert_eq "refresh: refreshed body passes _validate_implementation_brief_scope" "0" "$validator_rc"
validator_rc=0
_validate_implementation_brief_scope "21376" "$STALE_BODY" 1 "file-size-debt,auto-dispatch" || validator_rc=$?
assert_eq "refresh: stale body is the validator failure being repaired" "40" "$validator_rc"

# Test 6.5: finding an open stale debt issue rewrites it the same way.
reset_refresh_state
stub_issue "$STALE_BODY" "file-size-debt" "auto-dispatch"
_large_file_gate_find_existing_debt_issue() {
	printf 'open:21376'
	return 0
}
_large_file_gate_close_duplicate_debt_issues() { return 0; }
out=$(_large_file_gate_create_debt_issue "$LF_PATH" "37939" "owner/repo" "")
assert_eq "refresh: open reuse result unchanged" "#21376 (existing)" "$out"
assert_eq "refresh: open reuse writes one body edit" "1" "$(edit_count)"
assert_eq "refresh: open reuse body is the current template for the held issue" \
	"$(_large_file_gate_debt_issue_body "$LF_PATH" "37939" "")" \
	"$(cat "$EDIT_BODY" 2>/dev/null)"

# Test 6.6: a body that already declares a scope is never edited.
reset_refresh_state
stub_issue "$EXPECTED_NEW_BODY" "file-size-debt"
_large_file_gate_create_debt_issue "$LF_PATH" "40000" "owner/repo" "" >/dev/null
assert_eq "refresh: scoped body is not edited" "0" "$(edit_count)"

# Test 6.7: a body without this path's generator marker is never edited.
reset_refresh_state
stub_issue "${STALE_BODY//cited_file=${LF_PATH} /cited_file=other.sh }" "file-size-debt"
_large_file_gate_create_debt_issue "$LF_PATH" "37939" "owner/repo" "" >/dev/null
assert_eq "refresh: body for another cited path is not edited" "0" "$(edit_count)"
reset_refresh_state
stub_issue "Hand-written brief mentioning ${LF_PATH}" "file-size-debt"
_large_file_gate_create_debt_issue "$LF_PATH" "37939" "owner/repo" "" >/dev/null
assert_eq "refresh: body without the generator marker is not edited" "0" "$(edit_count)"

# Test 6.8: an issue without the file-size-debt label is never edited.
reset_refresh_state
stub_issue "$STALE_BODY" "auto-dispatch"
_large_file_gate_create_debt_issue "$LF_PATH" "37939" "owner/repo" "" >/dev/null
assert_eq "refresh: unlabelled issue is not edited" "0" "$(edit_count)"

# Test 6.9: a brief-owner hold keeps the body untouched.
reset_refresh_state
stub_issue "$STALE_BODY" "file-size-debt"
issue_brief_hold_blocks_auto_release() { return 0; }
_large_file_gate_create_debt_issue "$LF_PATH" "37939" "owner/repo" "" >/dev/null
assert_eq "refresh: brief-held body is not edited" "0" "$(edit_count)"
unset -f issue_brief_hold_blocks_auto_release

# Test 6.10: a failed edit logs one warning and leaves the result unchanged.
reset_refresh_state
stub_issue "$STALE_BODY" "file-size-debt"
STUB_EDIT_RC=1
reopen_rc=0
out=$(_large_file_gate_reopen_debt_issue "21376" "$LF_PATH" "owner/repo" "37939") || reopen_rc=$?
assert_eq "refresh: failed edit keeps reopen output" "#21376 (reopened)" "$out"
assert_eq "refresh: failed edit keeps reopen return code" "0" "$reopen_rc"
assert_eq "refresh: failed edit logs one warning" "1" \
	"$(grep -c 'WARN: reopened file-size-debt #21376 but failed to refresh its body' "$LOGFILE")"
STUB_EDIT_RC=0

######################################################################
# Summary
######################################################################

printf '\n=== Results: %d/%d passed ===\n\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%sFAILED%s — %d test(s) failed\n' "$TEST_RED" "$TEST_NC" "$TESTS_FAILED"
	exit 1
fi

printf '%sALL PASSED%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
