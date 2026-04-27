#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for bounty-spam-detector.sh (t2925, GH#21100).
#
# Two tiers:
#   1. Fixture-based scan-body tests using preserved bodies from the
#      canonical incident (carycooper777 PRs #21077, #21094, #21101).
#      These bodies are captured verbatim — the detector must hold the
#      line against the actual attack.
#   2. Negative tests using a legitimate framework PR body and a
#      meta-discussion body that quotes the attack patterns inside
#      fenced code blocks. Both must score clean.
#
# `set -e` is intentionally OMITTED — see the test harness template
# for rationale (we capture rc explicitly after each call).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/../bounty-spam-detector.sh"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures/bounty-spam"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Run scan-body against a fixture, return verdict and exit code.
# Args: $1 = fixture filename (relative to FIXTURE_DIR)
# Globals: sets FIXTURE_VERDICT, FIXTURE_EXIT
#
# NOTE: capture rc via `cmd ... || rc=$?` — using `cmd ... || true`
# clobbers the exit code with `true`'s 0.
run_fixture() {
	local fixture="$1"
	local out rc=0
	out=$("$SCRIPT_UNDER_TEST" scan-body --body-file "${FIXTURE_DIR}/${fixture}" 2>/dev/null) || rc=$?
	FIXTURE_VERDICT=$(printf '%s' "$out" | cut -d'|' -f1)
	FIXTURE_EXIT=$rc
	return 0
}

# ============================================================
# POSITIVE FIXTURES — must all score spam-likely (exit 1)
# ============================================================

test_positive_pr_21077() {
	run_fixture "positive-21077.body.md"
	if [[ "$FIXTURE_VERDICT" == "spam-likely" && "$FIXTURE_EXIT" -eq 1 ]]; then
		print_result "positive: PR #21077 (README.md spam) → spam-likely" 0
	else
		print_result "positive: PR #21077 (README.md spam) → spam-likely" 1 \
			"got verdict=${FIXTURE_VERDICT} exit=${FIXTURE_EXIT}"
	fi
	return 0
}

test_positive_pr_21094() {
	run_fixture "positive-21094.body.md"
	if [[ "$FIXTURE_VERDICT" == "spam-likely" && "$FIXTURE_EXIT" -eq 1 ]]; then
		print_result "positive: PR #21094 (tNNN-brief.md spam) → spam-likely" 0
	else
		print_result "positive: PR #21094 (tNNN-brief.md spam) → spam-likely" 1 \
			"got verdict=${FIXTURE_VERDICT} exit=${FIXTURE_EXIT}"
	fi
	return 0
}

test_positive_pr_21101() {
	# The recursive case — PR targeted issue #21100 itself.
	run_fixture "positive-21101.body.md"
	if [[ "$FIXTURE_VERDICT" == "spam-likely" && "$FIXTURE_EXIT" -eq 1 ]]; then
		print_result "positive: PR #21101 (recursive — targeted issue #21100) → spam-likely" 0
	else
		print_result "positive: PR #21101 (recursive — targeted issue #21100) → spam-likely" 1 \
			"got verdict=${FIXTURE_VERDICT} exit=${FIXTURE_EXIT}"
	fi
	return 0
}

# ============================================================
# NEGATIVE FIXTURES — must all score clean (exit 0)
# ============================================================

test_negative_legitimate_pr() {
	run_fixture "negative-legitimate-pr.body.md"
	if [[ "$FIXTURE_VERDICT" == "clean" && "$FIXTURE_EXIT" -eq 0 ]]; then
		print_result "negative: legitimate framework PR body → clean" 0
	else
		print_result "negative: legitimate framework PR body → clean" 1 \
			"got verdict=${FIXTURE_VERDICT} exit=${FIXTURE_EXIT}"
	fi
	return 0
}

test_negative_meta_discussion() {
	# Body discusses the attack class with quoted phrases in PROSE and
	# fenced code blocks. The detector must NOT auto-close — fence-stripping
	# removes the headers and field syntax, leaving only attribution
	# phrases (1 signal class) which is insufficient for spam-likely.
	run_fixture "negative-meta-discussion.body.md"
	if [[ "$FIXTURE_VERDICT" == "clean" && "$FIXTURE_EXIT" -eq 0 ]]; then
		print_result "negative: meta-discussion of attack (fenced refs) → clean" 0
	else
		print_result "negative: meta-discussion of attack (fenced refs) → clean" 1 \
			"got verdict=${FIXTURE_VERDICT} exit=${FIXTURE_EXIT}"
	fi
	return 0
}

# ============================================================
# CLI SMOKE TESTS — no network
# ============================================================

test_help_subcommand() {
	local out rc=0
	out=$("$SCRIPT_UNDER_TEST" help 2>&1) || rc=$?
	if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'bounty-spam-detector.sh' 2>/dev/null; then
		print_result "cli: help subcommand returns 0 and includes script name" 0
	else
		print_result "cli: help subcommand returns 0 and includes script name" 1 \
			"rc=$rc"
	fi
	return 0
}

test_unknown_subcommand_returns_3() {
	local rc=0
	"$SCRIPT_UNDER_TEST" __nonexistent_subcommand >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 3 ]]; then
		print_result "cli: unknown subcommand returns exit 3" 0
	else
		print_result "cli: unknown subcommand returns exit 3" 1 \
			"got rc=$rc (wanted 3)"
	fi
	return 0
}

test_close_refuses_issue_type() {
	# close should refuse to act on type=issue (auto-close on issues
	# is out of scope — issues stay open for triage).
	local rc=0
	"$SCRIPT_UNDER_TEST" close issue 99999 --repo example/example >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 3 ]]; then
		print_result "cli: close refuses type=issue (returns 3)" 0
	else
		print_result "cli: close refuses type=issue (returns 3)" 1 \
			"got rc=$rc (wanted 3)"
	fi
	return 0
}

test_scan_body_missing_file() {
	local rc=0
	"$SCRIPT_UNDER_TEST" scan-body --body-file /nonexistent/path.md >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 3 ]]; then
		print_result "cli: scan-body with missing file returns 3" 0
	else
		print_result "cli: scan-body with missing file returns 3" 1 \
			"got rc=$rc (wanted 3)"
	fi
	return 0
}

# ============================================================
# JSON OUTPUT SMOKE TEST
# ============================================================

test_score_json_well_formed() {
	# Build a tiny synthetic body, run scan-body, then ensure score
	# command via fixture-based test produces parseable JSON when --json
	# is implied through manual invocation.
	local tmp
	tmp=$(mktemp -t bsd-test.XXXXXX.md) || {
		print_result "json: well-formed output" 1 "could not mktemp"
		return 0
	}
	cat >"$tmp" <<'EOF'
## 💰 Paid Bounty Contribution
| **Reward** | **$1** |
| **Source** | GitHub-Paid |
🤖 *Generated via automated bounty hunter*
EOF
	# scan-body doesn't take --json; we test via score path on a fixture.
	# Since `score` requires gh access, we just validate that scan-body
	# pipeline works end-to-end on a synthetic body.
	local out rc=0
	out=$("$SCRIPT_UNDER_TEST" scan-body --body-file "$tmp" 2>/dev/null) || rc=$?
	rm -f "$tmp"
	if [[ "$rc" -eq 1 ]] && printf '%s' "$out" | grep -q '^spam-likely|' 2>/dev/null; then
		print_result "json: synthetic full-template body matches spam-likely" 0
	else
		print_result "json: synthetic full-template body matches spam-likely" 1 \
			"rc=$rc out=${out}"
	fi
	return 0
}

# ============================================================
# RUN
# ============================================================

main() {
	if [[ ! -x "$SCRIPT_UNDER_TEST" ]]; then
		printf 'ERROR: %s not executable\n' "$SCRIPT_UNDER_TEST" >&2
		exit 1
	fi
	if [[ ! -d "$FIXTURE_DIR" ]]; then
		printf 'ERROR: fixture dir %s missing\n' "$FIXTURE_DIR" >&2
		exit 1
	fi

	# Positive fixtures (the canonical attack)
	test_positive_pr_21077
	test_positive_pr_21094
	test_positive_pr_21101

	# Negative fixtures (legitimate content must not trigger)
	test_negative_legitimate_pr
	test_negative_meta_discussion

	# CLI smoke
	test_help_subcommand
	test_unknown_subcommand_returns_3
	test_close_refuses_issue_type
	test_scan_body_missing_file
	test_score_json_well_formed

	printf '\n--- %d tests run, %d failed ---\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] && exit 0
	exit 1
}

main "$@"
