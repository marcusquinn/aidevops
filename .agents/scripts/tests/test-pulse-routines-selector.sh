#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-routines-selector.sh — Regression tests for routine selector bugs
# fixed in pulse-routines.sh and routine-schedule-helper.sh:
#
# History:
#   t2160 — cron schedule extraction truncated at first space (fixed Apr 17)
#   t2175 — two false-match bugs (fixed Apr 18):
#   t2423 — Phase C metachar guard + Phase D end-to-end test (this PR)
#
# Bug 1 (t2175) — t-prefix false match: the grep selector
#   '^\s*-\s*\[x\].*repeat:' matched any completed task whose description text
#   contains the literal "repeat:" (e.g. t2160 quotes `repeat:([^[:space:]]+)`).
#   Combined with the unanchored routine-ID regex (r[0-9]+), this caused r-IDs
#   mentioned inside the description (like "r901, r902") to be treated as live
#   routine IDs and their neighbour text passed to the schedule parser.
#   Observed error: ERROR: unrecognised schedule expression '([^[:space:]]+)`'
#
# Bug 2 (t2175) — persistent unsupported: r912 in aidevops-routines/TODO.md
#   carries repeat:persistent (launchd-supervised daemon). The schedule parser
#   and the pulse evaluator both rejected this keyword.
#   Observed error: ERROR: unrecognised schedule expression 'persistent'
#
# Fixes verified here:
#   1. Tightened grep selector: '^\s*-\s*\[x\][[:space:]]+r[0-9]+[[:space:]].*repeat:'
#   2. Anchored routine-ID regex: ^[[:space:]]*-[[:space:]]\[x\][[:space:]]+(r[0-9]+)
#   3. persistent short-circuit in pulse-routines.sh evaluator loop
#   4. persistent handling in routine-schedule-helper.sh (cmd_is_due returns 1)
#   5. (t2423) Phase C metachar guard in routine-schedule-helper.sh _parse_expression
#
# Cases:
#   1. t-prefix with repeat: in description → selector finds 0 matches
#   2. r-prefix with repeat:persistent → selector finds 1 match; is-due returns
#      non-zero (not due) with no error output
#   3. r-prefix with repeat:cron(*/2 * * * *) → selector finds 1 match; no parse error
#   4. Mixed: t-prefix false-match line + two r-prefix routines → selector finds
#      exactly 2 matches (only the r-prefixed entries)
#   5. (t2423 Phase C) regex metachars directly passed to schedule helper → exit 2
#      with distinct error message, no "unrecognised schedule expression"
#   6. (t2423 Phase D) Full discovery simulation: mixed TODO with t-prefix false-match
#      lines produces zero "unrecognised schedule expression" errors on stderr

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCHEDULE_HELPER="${SCRIPT_DIR}/../routine-schedule-helper.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Create a minimal TODO.md in $1 with the given entries.
_make_todo() {
	local dir="$1"
	shift
	{
		printf '# Tasks\n\n'
		for entry in "$@"; do
			printf '%s\n' "$entry"
		done
	} >"${dir}/TODO.md"
	return 0
}

# The tightened selector from pulse-routines.sh (post-t2175).
# Must match the grep -E pattern used in the production script.
SELECTOR='^\s*-\s*\[x\][[:space:]]+r[0-9]+[[:space:]].*repeat:'

# _test_selector_cases: cases 1-4 — grep selector correctness (t2175)
_test_selector_cases() {
	local tmpdir="$1"
	local count

	# Case 1: t-prefix task with repeat: in description → 0 selector matches.
	# Mirrors t2160 TODO entry. OLD selector matched; NEW must not.
	_make_todo "$tmpdir" \
		"- [x] t2160 fix: \`repeat:([^[:space:]]+)\` (r901, r902) ref:GH#19465"
	# grep -c prints 0 even on no match; no || fallback needed.
	count=$(grep -cE "$SELECTOR" "${tmpdir}/TODO.md" 2>/dev/null; true)
	if [[ "$count" -eq 0 ]]; then
		pass "Case 1: t-prefix false-match prevented by tightened selector"
	else
		fail "Case 1: t-prefix false-match prevented" "expected 0 matches, got $count"
	fi

	# Case 2: r-prefix with repeat:persistent — selector matches, is-due skips.
	# Mirrors r912 in aidevops-routines/TODO.md (launchd-supervised daemon).
	_make_todo "$tmpdir" \
		"- [x] r912 Dashboard server repeat:persistent ~0s run:server/index.ts"
	count=$(grep -cE "$SELECTOR" "${tmpdir}/TODO.md" 2>/dev/null; true)
	local is_due_exit is_due_output
	is_due_output=$("$SCHEDULE_HELPER" is-due "persistent" "0" 2>&1)
	is_due_exit=$?
	if [[ "$count" -eq 1 ]] && [[ "$is_due_exit" -ne 0 ]] && [[ "$is_due_output" != *"ERROR"* ]]; then
		pass "Case 2: r-prefix persistent matches selector; is-due returns not-due with no error"
	else
		fail "Case 2: r-prefix persistent matches selector; is-due returns not-due with no error" \
			"count=$count is_due_exit=$is_due_exit output='$is_due_output'"
	fi

	# Case 3: r-prefix with cron schedule — selector matches, no parse error.
	_make_todo "$tmpdir" \
		"- [x] r901 Supervisor pulse repeat:cron(*/2 * * * *) ~0s agent:Build+"
	count=$(grep -cE "$SELECTOR" "${tmpdir}/TODO.md" 2>/dev/null; true)
	local cron_output
	cron_output=$("$SCHEDULE_HELPER" is-due "cron(*/2 * * * *)" "0" 2>&1 >/dev/null)
	if [[ "$count" -eq 1 ]] && [[ "$cron_output" != *"ERROR"* ]]; then
		pass "Case 3: r-prefix cron matches selector; schedule helper produces no parse error"
	else
		fail "Case 3: r-prefix cron matches selector; schedule helper produces no parse error" \
			"count=$count cron_stderr='$cron_output'"
	fi

	# Case 4: Mixed TODO — selector finds exactly 2 r-prefix entries, excludes t-prefix.
	_make_todo "$tmpdir" \
		"- [x] t2160 fix: \`repeat:([^[:space:]]+)\` (r901, r902) ref:GH#19465" \
		"- [x] r901 Supervisor pulse repeat:cron(*/2 * * * *) ~0s agent:Build+" \
		"- [x] r912 Dashboard server repeat:persistent ~0s run:server/index.ts"
	count=$(grep -cE "$SELECTOR" "${tmpdir}/TODO.md" 2>/dev/null; true)
	if [[ "$count" -eq 2 ]]; then
		pass "Case 4: mixed TODO — 2 r-prefix routines matched, t-prefix excluded"
	else
		fail "Case 4: mixed TODO — 2 r-prefix routines matched" "expected 2 matches, got $count"
	fi
	return 0
}

# _test_metachar_guard: case 5 — Phase C metachar guard (t2423)
_test_metachar_guard() {
	# Verifies that _parse_expression catches regex patterns before the generic
	# "unrecognised schedule expression" fallback. Guard must:
	#   a) exit 2 (distinct from normal parse error exit 1)
	#   b) emit "regex metacharacters" in the error message
	#   c) NOT emit "unrecognised schedule expression"
	local meta_exit meta_stderr
	meta_stderr=$("$SCHEDULE_HELPER" is-due '([^[:space:]]+)`' '0' 2>&1 >/dev/null)
	meta_exit=$?
	if [[ "$meta_exit" -eq 2 ]] && [[ "$meta_stderr" == *"regex metacharacters"* ]] && \
		[[ "$meta_stderr" != *"unrecognised schedule expression"* ]]; then
		pass "Case 5 (t2423 Phase C): metachar guard fires for regex pattern input"
	else
		fail "Case 5 (t2423 Phase C): metachar guard fires for regex pattern input" \
			"exit=$meta_exit stderr='$meta_stderr'"
	fi
	return 0
}

# _test_e2e_discovery: case 6 — Phase D end-to-end simulation (t2423)
_test_e2e_discovery() {
	local tmpdir="$1"
	# Simulates the full pulse-routines discovery path. TODO.md contains:
	#   - t-prefix tasks with repeat: in descriptions (t2175 false-match triggers)
	#   - Two valid r-prefix routines (cron + persistent)
	# All matched lines are piped through the extraction regex from pulse-routines.sh
	# and sent to routine-schedule-helper.sh is-due. Zero "unrecognised schedule
	# expression" errors must appear on stderr.
	_make_todo "$tmpdir" \
		"- [x] t2160 fix: \`repeat:([^[:space:]]+)\` (r901, r902) ref:GH#19465" \
		"- [x] t2423 guard: routine-schedule-helper.sh regex metachar guard" \
		"- [x] r901 Supervisor pulse repeat:cron(*/2 * * * *) ~0s agent:Build+" \
		"- [x] r912 Dashboard server repeat:persistent ~0s run:server/index.ts"

	# Store regex in variable — avoids bash misparsing the literal ')' inline.
	local re_repeat='repeat:(cron\([^)]*\)|[^[:space:]]+)'
	local e2e_errors=0
	local e2e_stderr=""
	local line repeat_expr _ise_out
	while IFS= read -r line; do
		repeat_expr=""
		if [[ "$line" =~ $re_repeat ]]; then
			repeat_expr="${BASH_REMATCH[1]}"
		else
			continue
		fi
		# Skip persistent — pulse-routines.sh short-circuits before calling is-due.
		if [[ "$repeat_expr" == "persistent" ]]; then continue; fi
		_ise_out=$("$SCHEDULE_HELPER" is-due "$repeat_expr" "0" 2>&1 >/dev/null)
		if [[ "$_ise_out" == *"unrecognised schedule expression"* ]]; then
			e2e_errors=$((e2e_errors + 1))
			e2e_stderr="${e2e_stderr}|${repeat_expr}: ${_ise_out}"
		fi
	done < <(grep -E "$SELECTOR" "${tmpdir}/TODO.md" 2>/dev/null || true)

	if [[ "$e2e_errors" -eq 0 ]]; then
		pass "Case 6 (t2423 Phase D): full discovery path — zero unrecognised schedule errors"
	else
		fail "Case 6 (t2423 Phase D): full discovery path — zero unrecognised schedule errors" \
			"got $e2e_errors error(s): $e2e_stderr"
	fi
	return 0
}

main() {
	local tmpdir
	tmpdir=$(mktemp -d) || { printf 'FATAL: mktemp failed\n' >&2; exit 1; }
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" EXIT

	_test_selector_cases "$tmpdir"
	_test_metachar_guard
	_test_e2e_discovery "$tmpdir"

	# === Summary ===
	printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:\n'
		printf '%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
