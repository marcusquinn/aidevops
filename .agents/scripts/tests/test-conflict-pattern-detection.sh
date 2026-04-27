#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for pattern-aware conflict classification (t2987 / GH#21379).
#
# Background: _dispatch_conflict_fix_worker in pulse-merge-feedback.sh used to
# write a generic conflict-feedback section. Workers picking up the rerouted
# issue would hit the same pattern-specific conflict again (e.g. Drizzle
# migration idx collision), causing a reroute loop. Three consecutive reroutes
# were observed in a managed private repo for the same migration conflict.
#
# This PR adds:
#   - _classify_conflicts_by_pattern(): reads .agents/configs/conflict-patterns.conf
#     and classifies file paths into DRIZZLE_MIGRATION / LOCKFILE / I18N_JSON /
#     GENERATED / CODE classes.
#   - _emit_conflict_pattern_guidance(): emits a "### Pattern-Specific Resolution
#     Guidance" Markdown block for non-CODE classifications.
#   - _build_conflict_feedback_section(): calls the two helpers and embeds
#     the pattern guidance between the file list and the generic worker guidance.
#
# Test strategy:
#   1. Source pulse-merge-feedback.sh directly (it sets LOGFILE default, no deps).
#   2. Unit-test _classify_conflicts_by_pattern with synthetic file lists.
#   3. Unit-test _emit_conflict_pattern_guidance output.
#   4. Smoke-test _build_conflict_feedback_section: verify the brief contains
#      "### Pattern-Specific Resolution Guidance" when a non-CODE pattern is
#      detected, and does NOT contain it for CODE-only input.
#
# Run: bash .agents/scripts/tests/test-conflict-pattern-detection.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
FEEDBACK_SCRIPT="${REPO_ROOT}/.agents/scripts/pulse-merge-feedback.sh"
CONF_FILE="${REPO_ROOT}/.agents/configs/conflict-patterns.conf"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
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
	if [[ $# -ge 2 && -n "$2" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
	if [[ ! -f "$FEEDBACK_SCRIPT" ]]; then
		printf '%sFAIL%s pulse-merge-feedback.sh not found at %s\n' \
			"$TEST_RED" "$TEST_NC" "$FEEDBACK_SCRIPT"
		return 1
	fi
	if [[ ! -f "$CONF_FILE" ]]; then
		printf '%sFAIL%s conflict-patterns.conf not found at %s\n' \
			"$TEST_RED" "$TEST_NC" "$CONF_FILE"
		return 1
	fi
	# Source the feedback module. LOGFILE defaults internally via : "${LOGFILE:=...}".
	# shellcheck source=/dev/null
	if ! source "$FEEDBACK_SCRIPT" 2>/dev/null; then
		printf '%sFAIL%s could not source %s\n' \
			"$TEST_RED" "$TEST_NC" "$FEEDBACK_SCRIPT"
		return 1
	fi
	pass "prerequisites: conf file + feedback script present and sourceable"
	return 0
}

# ── Conf file structural checks ──────────────────────────────────────────────

test_conf_has_drizzle_pattern() {
	if grep -qF '/migrations/meta/' "$CONF_FILE"; then
		pass "conf: DRIZZLE_MIGRATION pattern present (/migrations/meta/)"
		return 0
	fi
	fail "conf: DRIZZLE_MIGRATION pattern missing" \
		"Expected '/migrations/meta/' entry in conflict-patterns.conf"
	return 0
}

test_conf_has_lockfile_patterns() {
	local missing=0
	for lf in pnpm-lock.yaml package-lock.json yarn.lock; do
		if ! grep -qF "$lf" "$CONF_FILE"; then
			fail "conf: lockfile pattern missing: $lf" ""
			missing=$((missing + 1))
		fi
	done
	if [[ "$missing" -eq 0 ]]; then
		pass "conf: all three primary lockfile patterns present"
	fi
	return 0
}

test_conf_has_i18n_pattern() {
	if grep -qF '/translations/' "$CONF_FILE"; then
		pass "conf: I18N_JSON pattern present (/translations/)"
		return 0
	fi
	fail "conf: I18N_JSON pattern missing" \
		"Expected '/translations/' entry in conflict-patterns.conf"
	return 0
}

# ── _classify_conflicts_by_pattern unit tests ────────────────────────────────

assert_class() {
	local label="$1"
	local file_list="$2"
	local expected_class="$3"
	local got
	got=$(_classify_conflicts_by_pattern "$file_list" "$CONF_FILE")
	if echo "$got" | grep -q "^${expected_class} "; then
		pass "classify: $label → $expected_class"
		return 0
	fi
	fail "classify: $label → expected $expected_class" \
		"Got: $(echo "$got" | head -5)"
	return 0
}

assert_no_class() {
	local label="$1"
	local file_list="$2"
	local absent_class="$3"
	local got
	got=$(_classify_conflicts_by_pattern "$file_list" "$CONF_FILE")
	if echo "$got" | grep -q "^${absent_class} "; then
		fail "classify: $label — expected NO $absent_class line" \
			"Got: $(echo "$got" | head -5)"
		return 0
	fi
	pass "classify: $label → no spurious $absent_class"
	return 0
}

test_classify_drizzle_journal() {
	assert_class "Drizzle journal" \
		"packages/db/migrations/meta/_journal.json" \
		"DRIZZLE_MIGRATION"
	return 0
}

test_classify_drizzle_snapshot() {
	assert_class "Drizzle snapshot" \
		"packages/db/migrations/meta/0084_snapshot.json" \
		"DRIZZLE_MIGRATION"
	return 0
}

test_classify_pnpm_lockfile() {
	assert_class "pnpm lockfile" "pnpm-lock.yaml" "LOCKFILE"
	return 0
}

test_classify_npm_lockfile() {
	assert_class "npm lockfile" "package-lock.json" "LOCKFILE"
	return 0
}

test_classify_yarn_lockfile() {
	assert_class "yarn lockfile" "yarn.lock" "LOCKFILE"
	return 0
}

test_classify_i18n_translation() {
	assert_class "i18n translation" \
		"packages/i18n/src/translations/en/dashboard.json" \
		"I18N_JSON"
	return 0
}

test_classify_code_fallback() {
	assert_class "CODE fallback" \
		"packages/api/src/routes/users.ts" \
		"CODE"
	return 0
}

test_classify_code_no_drizzle_spurious() {
	# Normal TS file should NOT be classified as DRIZZLE_MIGRATION
	assert_no_class "no spurious DRIZZLE for .ts" \
		"apps/web/src/pages/settings.tsx" \
		"DRIZZLE_MIGRATION"
	return 0
}

test_classify_mixed_patterns() {
	# A mixed PR: Drizzle + lockfile + code
	local file_list
	file_list=$(printf '%s\n' \
		"packages/db/migrations/meta/_journal.json" \
		"pnpm-lock.yaml" \
		"packages/api/src/users.ts")
	local got
	got=$(_classify_conflicts_by_pattern "$file_list" "$CONF_FILE")

	local ok=0
	if echo "$got" | grep -q "^DRIZZLE_MIGRATION "; then ok=$((ok + 1)); fi
	if echo "$got" | grep -q "^LOCKFILE ";           then ok=$((ok + 1)); fi
	if echo "$got" | grep -q "^CODE ";               then ok=$((ok + 1)); fi

	if [[ "$ok" -eq 3 ]]; then
		pass "classify: mixed PR → DRIZZLE_MIGRATION + LOCKFILE + CODE"
		return 0
	fi
	fail "classify: mixed PR — expected 3 classes, found $ok" \
		"Got: $got"
	return 0
}

test_classify_code_only_no_drizzle() {
	# All CODE — no pattern guidance should fire
	local file_list
	file_list=$(printf '%s\n' \
		"apps/web/src/pages/index.tsx" \
		"packages/api/src/routes/health.ts")
	local got
	got=$(_classify_conflicts_by_pattern "$file_list" "$CONF_FILE")
	if echo "$got" | grep -qE "^(DRIZZLE_MIGRATION|LOCKFILE|I18N_JSON|GENERATED) "; then
		fail "classify: code-only PR — unexpected non-CODE classification" \
			"Got: $got"
		return 0
	fi
	pass "classify: code-only PR → CODE only, no pattern lines"
	return 0
}

# ── _emit_conflict_pattern_guidance unit tests ───────────────────────────────

test_guidance_emits_header_for_drizzle() {
	local classifications="DRIZZLE_MIGRATION packages/db/migrations/meta/_journal.json"
	local got
	got=$(_emit_conflict_pattern_guidance "$classifications" "develop")
	if echo "$got" | grep -q "### Pattern-Specific Resolution Guidance"; then
		pass "guidance: header emitted for DRIZZLE_MIGRATION"
		return 0
	fi
	fail "guidance: header missing for DRIZZLE_MIGRATION" \
		"Output: $(echo "$got" | head -5)"
	return 0
}

test_guidance_drizzle_mentions_db_generate() {
	local classifications="DRIZZLE_MIGRATION packages/db/migrations/meta/0084_snapshot.json"
	local got
	got=$(_emit_conflict_pattern_guidance "$classifications" "main")
	if echo "$got" | grep -q "db:generate"; then
		pass "guidance: DRIZZLE_MIGRATION mentions db:generate"
		return 0
	fi
	fail "guidance: DRIZZLE_MIGRATION missing db:generate step" \
		"Output: $(echo "$got" | head -10)"
	return 0
}

test_guidance_drizzle_has_warning() {
	local classifications="DRIZZLE_MIGRATION packages/db/migrations/meta/_journal.json"
	local got
	got=$(_emit_conflict_pattern_guidance "$classifications" "main")
	if echo "$got" | grep -iq "WARNING"; then
		pass "guidance: DRIZZLE_MIGRATION includes WARNING about snapshot corruption"
		return 0
	fi
	fail "guidance: DRIZZLE_MIGRATION missing WARNING block" \
		"Output: $(echo "$got" | head -15)"
	return 0
}

test_guidance_lockfile_mentions_no_frozen() {
	local classifications="LOCKFILE pnpm-lock.yaml"
	local got
	got=$(_emit_conflict_pattern_guidance "$classifications" "main")
	if echo "$got" | grep -q "no-frozen-lockfile"; then
		pass "guidance: LOCKFILE mentions --no-frozen-lockfile"
		return 0
	fi
	fail "guidance: LOCKFILE missing --no-frozen-lockfile hint" \
		"Output: $(echo "$got" | head -10)"
	return 0
}

test_guidance_i18n_mentions_jq_union() {
	local classifications="I18N_JSON packages/i18n/src/translations/en/dashboard.json"
	local got
	got=$(_emit_conflict_pattern_guidance "$classifications" "main")
	if echo "$got" | grep -q "jq"; then
		pass "guidance: I18N_JSON mentions jq union merge"
		return 0
	fi
	fail "guidance: I18N_JSON missing jq union merge step" \
		"Output: $(echo "$got" | head -10)"
	return 0
}

test_guidance_code_only_is_empty() {
	local classifications="CODE packages/api/src/users.ts"
	local got
	got=$(_emit_conflict_pattern_guidance "$classifications" "main")
	if [[ -z "$got" ]]; then
		pass "guidance: CODE-only input produces empty output"
		return 0
	fi
	fail "guidance: CODE-only input should produce no output" \
		"Got: $got"
	return 0
}

test_guidance_empty_input_is_empty() {
	local got
	got=$(_emit_conflict_pattern_guidance "" "main")
	if [[ -z "$got" ]]; then
		pass "guidance: empty input produces empty output"
		return 0
	fi
	fail "guidance: empty input should produce no output" \
		"Got: $got"
	return 0
}

# ── _build_conflict_feedback_section integration smoke tests ─────────────────

test_brief_has_pattern_guidance_for_drizzle() {
	local files="packages/db/migrations/meta/_journal.json"
	local got
	got=$(_build_conflict_feedback_section \
		"3047" "feat: add voice usage" "$files" "abc1234" "develop" "1")
	if echo "$got" | grep -q "### Pattern-Specific Resolution Guidance"; then
		pass "brief: contains Pattern-Specific Resolution Guidance for Drizzle file"
		return 0
	fi
	fail "brief: Pattern-Specific Resolution Guidance missing for Drizzle file" \
		"Output (first 20 lines): $(echo "$got" | head -20)"
	return 0
}

test_brief_has_pattern_guidance_mixed_pr() {
	local files
	files=$(printf '%s\n' \
		"packages/db/migrations/meta/_journal.json" \
		"pnpm-lock.yaml" \
		"packages/i18n/src/translations/en/dashboard.json" \
		"packages/api/src/users.ts")
	local got
	got=$(_build_conflict_feedback_section \
		"3088" "feat: add dashboard i18n" "$files" "def5678" "main" "4")

	local ok=0
	if echo "$got" | grep -q "### Pattern-Specific Resolution Guidance"; then ok=$((ok + 1)); fi
	if echo "$got" | grep -q "db:generate"; then ok=$((ok + 1)); fi
	if echo "$got" | grep -q "jq"; then ok=$((ok + 1)); fi
	if echo "$got" | grep -q "no-frozen-lockfile"; then ok=$((ok + 1)); fi
	if echo "$got" | grep -q "### Worker guidance"; then ok=$((ok + 1)); fi

	if [[ "$ok" -eq 5 ]]; then
		pass "brief: mixed PR — pattern guidance + worker guidance all present"
		return 0
	fi
	fail "brief: mixed PR — only $ok/5 expected sections present" \
		"Output (first 40 lines): $(echo "$got" | head -40)"
	return 0
}

test_brief_no_pattern_guidance_for_code_only() {
	local files
	files=$(printf '%s\n' \
		"apps/web/src/pages/index.tsx" \
		"packages/api/src/routes/health.ts")
	local got
	got=$(_build_conflict_feedback_section \
		"3326" "fix: correct user lookup" "$files" "fed9012" "main" "2")
	if echo "$got" | grep -q "### Pattern-Specific Resolution Guidance"; then
		fail "brief: code-only PR should NOT have Pattern-Specific Resolution Guidance" \
			"Output (first 20 lines): $(echo "$got" | head -20)"
		return 0
	fi
	if echo "$got" | grep -q "### Worker guidance"; then
		pass "brief: code-only PR → no pattern guidance, worker guidance present"
		return 0
	fi
	fail "brief: code-only PR missing ### Worker guidance" \
		"Output: $(echo "$got" | head -20)"
	return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main_test() {
	if ! check_prerequisites; then
		return 1
	fi

	printf '\nConf file checks:\n'
	test_conf_has_drizzle_pattern
	test_conf_has_lockfile_patterns
	test_conf_has_i18n_pattern

	printf '\n_classify_conflicts_by_pattern unit tests:\n'
	test_classify_drizzle_journal
	test_classify_drizzle_snapshot
	test_classify_pnpm_lockfile
	test_classify_npm_lockfile
	test_classify_yarn_lockfile
	test_classify_i18n_translation
	test_classify_code_fallback
	test_classify_code_no_drizzle_spurious
	test_classify_mixed_patterns
	test_classify_code_only_no_drizzle

	printf '\n_emit_conflict_pattern_guidance unit tests:\n'
	test_guidance_emits_header_for_drizzle
	test_guidance_drizzle_mentions_db_generate
	test_guidance_drizzle_has_warning
	test_guidance_lockfile_mentions_no_frozen
	test_guidance_i18n_mentions_jq_union
	test_guidance_code_only_is_empty
	test_guidance_empty_input_is_empty

	printf '\n_build_conflict_feedback_section integration tests:\n'
	test_brief_has_pattern_guidance_for_drizzle
	test_brief_has_pattern_guidance_mixed_pr
	test_brief_no_pattern_guidance_for_code_only

	printf '\nRan %d tests, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
