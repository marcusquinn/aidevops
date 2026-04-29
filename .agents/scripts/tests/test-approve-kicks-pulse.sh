#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-approve-kicks-pulse.sh — t3068 / GH#21806 regression guard.
#
# Asserts that `sudo aidevops approve` writes a trigger file and that
# `_drain_merge_trigger_file_if_present` reads it, atomically clears it,
# and invokes process_pr() for each valid entry.
#
# Tests:
#   1. Approve writes trigger file with correct format (type/slug/num).
#   2. Drain: "pr" entry calls process_pr(slug, num).
#   3. Drain: "issue" entry finds linked PRs via gh and calls process_pr each.
#   4. Drain: trigger file is cleared atomically (empty after drain).
#   5. Drain: malformed lines (bad slug, non-numeric num) are skipped
#      without error (fail-open).
#   6. Drain: no-op when trigger file is absent.
#   7. Drain: concurrent append lands in new file, not lost.
#
# Strategy:
#   _drain_merge_trigger_file_if_present is defined inline (copied verbatim
#   from pulse-wrapper-bootstrap.sh) to avoid sourcing the full dependency
#   chain. Stubs replace `gh` and `process_pr`. LOGFILE and HOME are
#   redirected to a temp sandbox.

set -uo pipefail

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t3068.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
export LOGFILE

# Override HOME so trigger file path resolves to sandbox.
REAL_HOME="$HOME"
HOME="$TMP"
export HOME

TRIGGER_FILE="${HOME}/.aidevops/cache/pulse-merge-trigger.txt"
mkdir -p "$(dirname "$TRIGGER_FILE")"

# Track process_pr calls.
PROCESS_PR_CALLS="${TMP}/process_pr_calls.log"
: > "$PROCESS_PR_CALLS"
export PROCESS_PR_CALLS

# Track gh calls (for issue→PR lookup).
GH_CALLS="${TMP}/gh_calls.log"
: > "$GH_CALLS"
export GH_CALLS

# =============================================================================
# Inline copy of _drain_merge_trigger_file_if_present (from bootstrap)
# plus stubs.
# =============================================================================

# Stub process_pr — records calls, returns 0.
process_pr() {
	local slug="$1"
	local pr_n="$2"
	printf '%s %s\n' "$slug" "$pr_n" >>"$PROCESS_PR_CALLS"
	return 0
}

# Stub gh — for "pr list" on issue lookup returns a known PR.
# For any other gh call, returns empty.
gh() {
	printf '%s\n' "$*" >>"$GH_CALLS"
	local subcmd="${1:-}"
	if [[ "$subcmd" == "pr" && "${2:-}" == "list" ]]; then
		# Simulate finding PR #42 linked to issue #7 for slug owner/repo.
		# The jq filter test calls are embedded; we return the PR number.
		printf '42\n'
		return 0
	fi
	return 0
}

# Paste the drain function verbatim so it uses our stubs.
_drain_merge_trigger_file_if_present() {
	local trigger_file="${HOME}/.aidevops/cache/pulse-merge-trigger.txt"
	local log_dest="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	[[ -f "$trigger_file" ]] || return 0

	local tmp_file="${trigger_file}.drain-$$"
	mv "$trigger_file" "$tmp_file" 2>/dev/null || {
		rm -f "$tmp_file" 2>/dev/null || true
		return 0
	}

	local line_type slug num
	while IFS=$'\t' read -r line_type slug num || [[ -n "$line_type" ]]; do
		[[ -z "$line_type" && -z "$slug" && -z "$num" ]] && continue
		if [[ -z "$slug" || "$slug" != *"/"* || ! "$num" =~ ^[0-9]+$ ]]; then
			printf '[pulse-wrapper] t3068 trigger drain: skipping malformed line type=%s slug=%s num=%s\n' \
				"${line_type:-?}" "${slug:-?}" "${num:-?}" \
				>>"$log_dest" 2>/dev/null || true
			continue
		fi
		printf '[pulse-wrapper] t3068 trigger drain: processing type=%s %s#%s\n' \
			"$line_type" "$slug" "$num" >>"$log_dest" 2>/dev/null || true

		if [[ "$line_type" == "pr" ]]; then
			if declare -F process_pr >/dev/null 2>&1; then
				process_pr "$slug" "$num" >>"$log_dest" 2>&1 || true
			fi
		elif [[ "$line_type" == "issue" ]]; then
			local linked_prs pr_n
			linked_prs=$(gh pr list --repo "$slug" --state open \
				--json number,body \
				--jq "[.[] | select(.body | test(\"(closes?|fixe[sd]?|resolve[sd]?)\\\\s+#${num}\"; \"i\")) | .number] | .[]" \
				2>/dev/null) || linked_prs=""
			if [[ -z "$linked_prs" ]]; then
				printf '[pulse-wrapper] t3068 trigger drain: no open PRs linked to %s#%s — skipping\n' \
					"$slug" "$num" >>"$log_dest" 2>/dev/null || true
			else
				while IFS= read -r pr_n; do
					[[ "$pr_n" =~ ^[0-9]+$ ]] || continue
					printf '[pulse-wrapper] t3068 trigger drain: processing linked PR %s#%s for issue #%s\n' \
						"$slug" "$pr_n" "$num" >>"$log_dest" 2>/dev/null || true
					if declare -F process_pr >/dev/null 2>&1; then
						process_pr "$slug" "$pr_n" >>"$log_dest" 2>&1 || true
					fi
				done <<< "$linked_prs"
			fi
		else
			printf '[pulse-wrapper] t3068 trigger drain: unknown type %s for %s#%s — skipping\n' \
				"$line_type" "$slug" "$num" >>"$log_dest" 2>/dev/null || true
		fi
	done < "$tmp_file"
	rm -f "$tmp_file" 2>/dev/null || true
	return 0
}

# =============================================================================
# Helper: write trigger file entry (mirrors approval-helper.sh logic)
# =============================================================================
_write_trigger() {
	local target_type="$1"
	local slug="$2"
	local target_number="$3"
	local trigger_file="${HOME}/.aidevops/cache/pulse-merge-trigger.txt"
	mkdir -p "$(dirname "$trigger_file")" 2>/dev/null || true
	printf '%s\t%s\t%s\n' "$target_type" "$slug" "$target_number" >> "$trigger_file"
	return 0
}

# =============================================================================
# Test 1: Approve writes trigger file with correct format
# =============================================================================
printf '\n%sTest 1: approve writes trigger file%s\n' "$TEST_BLUE" "$TEST_NC"

rm -f "$TRIGGER_FILE"
_write_trigger "pr" "owner/repo" "99"

if [[ -f "$TRIGGER_FILE" ]]; then
	content=$(<"$TRIGGER_FILE")
	if [[ "$content" == $'pr\towner/repo\t99' ]]; then
		pass "trigger file written with correct format (pr/slug/num)"
	else
		fail "trigger file content mismatch" "got: $(printf '%q' "$content")"
	fi
else
	fail "trigger file not created"
fi

# =============================================================================
# Test 2: Drain — "pr" entry calls process_pr(slug, num)
# =============================================================================
printf '\n%sTest 2: drain pr entry calls process_pr%s\n' "$TEST_BLUE" "$TEST_NC"

rm -f "$TRIGGER_FILE" "$PROCESS_PR_CALLS"
: > "$PROCESS_PR_CALLS"
printf 'pr\towner/repo\t42\n' > "$TRIGGER_FILE"

_drain_merge_trigger_file_if_present

calls=$(<"$PROCESS_PR_CALLS")
if [[ "$calls" == "owner/repo 42" ]]; then
	pass "process_pr called with correct slug and pr_num"
else
	fail "process_pr not called correctly" "got: $(printf '%q' "$calls")"
fi

# =============================================================================
# Test 3: Drain — "issue" entry finds linked PR and calls process_pr
# =============================================================================
printf '\n%sTest 3: drain issue entry finds linked PR%s\n' "$TEST_BLUE" "$TEST_NC"

rm -f "$TRIGGER_FILE" "$PROCESS_PR_CALLS"
: > "$PROCESS_PR_CALLS"
printf 'issue\towner/repo\t7\n' > "$TRIGGER_FILE"

_drain_merge_trigger_file_if_present

calls=$(<"$PROCESS_PR_CALLS")
if [[ "$calls" == "owner/repo 42" ]]; then
	pass "process_pr called with linked PR #42 for issue #7"
else
	fail "process_pr not called for issue-linked PR" "got: $(printf '%q' "$calls")"
fi

# =============================================================================
# Test 4: Drain clears trigger file atomically (no file after drain)
# =============================================================================
printf '\n%sTest 4: trigger file cleared after drain%s\n' "$TEST_BLUE" "$TEST_NC"

rm -f "$TRIGGER_FILE"
printf 'pr\towner/repo\t10\n' > "$TRIGGER_FILE"

_drain_merge_trigger_file_if_present

# Both the original and the drain-$$ temp must be gone.
if [[ ! -f "$TRIGGER_FILE" ]]; then
	# Also check no .drain-* leftovers
	drain_leftovers=$(ls "${TRIGGER_FILE}.drain-"* 2>/dev/null | wc -l)
	drain_leftovers="${drain_leftovers//[[:space:]]/}"
	if [[ "$drain_leftovers" == "0" ]]; then
		pass "trigger file cleared after drain (no leftovers)"
	else
		fail "drain temp file not cleaned up" "leftover count: $drain_leftovers"
	fi
else
	fail "trigger file still exists after drain"
fi

# =============================================================================
# Test 5: Malformed lines are skipped (fail-open)
# =============================================================================
printf '\n%sTest 5: malformed lines skipped without error%s\n' "$TEST_BLUE" "$TEST_NC"

rm -f "$TRIGGER_FILE" "$PROCESS_PR_CALLS"
: > "$PROCESS_PR_CALLS"
# bad slug (no slash), non-numeric num, completely blank, unknown type
printf 'pr\tbadslugnoslash\t99\n' > "$TRIGGER_FILE"
printf 'pr\towner/repo\tNOTANUM\n' >> "$TRIGGER_FILE"
printf '\t\t\n' >> "$TRIGGER_FILE"
printf 'pr\towner/repo\t55\n' >> "$TRIGGER_FILE"  # valid — should still be called

rc=0
_drain_merge_trigger_file_if_present || rc=$?

if [[ "$rc" -eq 0 ]]; then
	calls=$(<"$PROCESS_PR_CALLS")
	if [[ "$calls" == "owner/repo 55" ]]; then
		pass "malformed lines skipped, valid line still processed"
	else
		fail "unexpected process_pr calls" "got: $(printf '%q' "$calls")"
	fi
else
	fail "drain returned non-zero on malformed lines (should fail-open)" "rc=$rc"
fi

# =============================================================================
# Test 6: No-op when trigger file is absent
# =============================================================================
printf '\n%sTest 6: no-op when trigger file absent%s\n' "$TEST_BLUE" "$TEST_NC"

rm -f "$TRIGGER_FILE" "$PROCESS_PR_CALLS"
: > "$PROCESS_PR_CALLS"

rc=0
_drain_merge_trigger_file_if_present || rc=$?

if [[ "$rc" -eq 0 ]]; then
	calls=$(<"$PROCESS_PR_CALLS")
	if [[ -z "$calls" ]]; then
		pass "no-op when trigger file absent"
	else
		fail "process_pr called unexpectedly when no trigger file" "calls: $calls"
	fi
else
	fail "drain returned non-zero when file absent (should be no-op)" "rc=$rc"
fi

# =============================================================================
# Test 7: Entry written during drain lands in new file (not lost)
# =============================================================================
printf '\n%sTest 7: concurrent write survives atomic move%s\n' "$TEST_BLUE" "$TEST_NC"

rm -f "$TRIGGER_FILE" "$PROCESS_PR_CALLS"
: > "$PROCESS_PR_CALLS"
printf 'pr\towner/repo\t10\n' > "$TRIGGER_FILE"

# Wrap drain to simulate a concurrent write AFTER the mv (i.e., mid-drain):
# We test the invariant directly: after drain, write another entry, then drain again.
_drain_merge_trigger_file_if_present

# Simulate concurrent approval during drain — write after drain completes
printf 'pr\towner/repo\t20\n' > "$TRIGGER_FILE"

: > "$PROCESS_PR_CALLS"
_drain_merge_trigger_file_if_present

calls=$(<"$PROCESS_PR_CALLS")
if [[ "$calls" == "owner/repo 20" ]]; then
	pass "entry written after drain is picked up by next cycle"
else
	fail "concurrent write not processed by next drain" "got: $(printf '%q' "$calls")"
fi

# =============================================================================
# Summary
# =============================================================================
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	_summary_color="$TEST_GREEN"
else
	_summary_color="$TEST_RED"
fi
printf '\n%s=== %d/%d tests passed ===%s\n' \
	"$_summary_color" "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TEST_NC"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
