#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-routines-selector.sh — Regression tests for the two false-match
# bugs fixed in pulse-routines.sh by t2175:
#
# Bug 1 — t-prefix false match: the grep selector
#   '^\s*-\s*\[x\].*repeat:' matched any completed task whose description text
#   contains the literal "repeat:" (e.g. t2160 quotes `repeat:([^[:space:]]+)`).
#   Combined with the unanchored routine-ID regex (r[0-9]+), this caused r-IDs
#   mentioned inside the description (like "r901, r902") to be treated as live
#   routine IDs and their neighbour text passed to the schedule parser.
#   Observed error: ERROR: unrecognised schedule expression '([^[:space:]]+)`'
#
# Bug 2 — persistent unsupported: r912 in aidevops-routines/TODO.md carries
#   repeat:persistent (launchd-supervised daemon). The schedule parser and the
#   pulse evaluator both rejected this keyword.
#   Observed error: ERROR: unrecognised schedule expression 'persistent'
#
# Fixes verified here:
#   1. Tightened grep selector: '^\s*-\s*\[x\][[:space:]]+r[0-9]+[[:space:]].*repeat:'
#   2. Anchored routine-ID regex: ^[[:space:]]*-[[:space:]]\[x\][[:space:]]+(r[0-9]+)
#   3. persistent short-circuit in pulse-routines.sh evaluator loop
#   4. persistent handling in routine-schedule-helper.sh (cmd_is_due returns 1)
#
# Cases:
#   1. t-prefix with repeat: in description → selector finds 0 matches
#   2. r-prefix with repeat:persistent → selector finds 1 match; is-due returns
#      non-zero (not due) with no error output
#   3. r-prefix with repeat:cron(*/2 * * * *) → selector finds 1 match; no parse error
#   4. Mixed: t-prefix false-match line + two r-prefix routines → selector finds
#      exactly 2 matches (only the r-prefixed entries)

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

main() {
	local tmpdir
	tmpdir=$(mktemp -d) || { printf 'FATAL: mktemp failed\n' >&2; exit 1; }
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" EXIT

	# === Case 1: t-prefix task with repeat: in description → 0 selector matches ===
	# Mirrors the t2160 TODO.md entry that triggered bug 1.  The description quotes
	# the repeat: regex and lists r901/r902 as example routine IDs.  With the OLD
	# selector, this line matched; with the NEW selector it must not.
	_make_todo "$tmpdir" \
		"- [x] t2160 fix: \`repeat:([^[:space:]]+)\` (r901, r902) ref:GH#19465"
	local count
	# grep -c always prints the count even when 0; no || fallback needed.
	count=$(grep -cE "$SELECTOR" "${tmpdir}/TODO.md" 2>/dev/null; true)
	if [[ "$count" -eq 0 ]]; then
		pass "Case 1: t-prefix false-match prevented by tightened selector"
	else
		fail "Case 1: t-prefix false-match prevented" "expected 0 matches, got $count"
	fi

	# === Case 2: r-prefix with repeat:persistent — selector matches, is-due skips ===
	# Mirrors r912 in aidevops-routines/TODO.md (launchd-supervised dashboard).
	# Verifies both that the selector captures the line AND that is-due treats it
	# as "not due" with no ERROR output (bug t2175 fix #2).
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

	# === Case 3: r-prefix with cron schedule — selector matches, no parse error ===
	# Verifies that a standard cron routine still works after the selector tightening.
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

	# === Case 4: Mixed TODO — t-prefix false-match + 2 r-prefix routines ===
	# The selector must find exactly 2 matches (the r-prefix entries) and exclude
	# the t-prefix task even though its description contains repeat: and r-IDs.
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
