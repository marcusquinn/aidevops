#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-conflict-pattern-detection.sh — Structural tests for t2987 pattern-aware
# conflict resolution guidance in pulse-merge-feedback.sh.
#
# Verifies:
#   1. conflict-patterns.conf exists and is the single source of truth
#   2. _classify_conflicts_by_pattern identifies DRIZZLE_MIGRATION correctly
#   3. _classify_conflicts_by_pattern identifies LOCKFILE correctly
#   4. _classify_conflicts_by_pattern identifies I18N_JSON correctly
#   5. _classify_conflicts_by_pattern identifies GENERATED correctly
#   6. _classify_conflicts_by_pattern falls back to CODE for unmatched files
#   7. Mixed-pattern PR: multiple classifications emitted on separate lines
#   8. Empty file list: no classification output
#   9. _build_conflict_feedback_section emits ### Pattern-Specific Resolution
#      Guidance block when non-CODE patterns are present
#  10. _build_conflict_feedback_section does NOT emit the guidance block for
#      CODE-only conflicts
#  11. Drizzle guidance block contains renumbering warning
#  12. Lockfile guidance block contains regeneration command
#  13. i18n guidance block mentions jq union-merge
#  14. pulse-merge-feedback.sh passes shellcheck
#
# Tests are structural — no live GitHub API calls.

set -u

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

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in output:        $(printf '%q' "${haystack:0:200}")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected NOT to find: $(printf '%q' "$needle")"
		echo "  in output:            $(printf '%q' "${haystack:0:200}")"
	fi
	return 0
}

assert_empty() {
	local label="$1" value="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -z "$value" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected empty, got: $(printf '%q' "${value:0:200}")"
	fi
	return 0
}

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc=$expected, got rc=$actual"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate files and source the module under test.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/pulse-merge-feedback.sh"
CONF_FILE="$SCRIPT_DIR/../configs/conflict-patterns.conf"

if [[ ! -f "$MODULE" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $MODULE not found"
	exit 1
fi

# Source with minimal stubs so the module's set-u guard is satisfied.
export LOGFILE="${LOGFILE:-/tmp/test-conflict-pattern-$$.log}"
# shellcheck source=/dev/null
source "$MODULE"

echo "${TEST_BLUE}=== t2987: conflict-pattern detection tests ===${TEST_NC}"
echo ""

# ---------------------------------------------------------------------------
# Test 1: conf file exists and is not empty.
# ---------------------------------------------------------------------------
echo "--- Section 1: conf file integrity ---"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$CONF_FILE" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1a: conflict-patterns.conf exists"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1a: conflict-patterns.conf NOT found at $CONF_FILE"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^DRIZZLE_MIGRATION' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1b: conf contains DRIZZLE_MIGRATION entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1b: conf missing DRIZZLE_MIGRATION entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^LOCKFILE' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1c: conf contains LOCKFILE entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1c: conf missing LOCKFILE entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^I18N_JSON' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1d: conf contains I18N_JSON entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1d: conf missing I18N_JSON entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^GENERATED' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1e: conf contains GENERATED entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1e: conf missing GENERATED entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^CODE' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1f: conf contains CODE catch-all entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1f: conf missing CODE catch-all entry"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 2: _classify_conflicts_by_pattern — per-pattern classification.
# ---------------------------------------------------------------------------
echo "--- Section 2: _classify_conflicts_by_pattern ---"

# 2a: Drizzle journal
drizzle_out=$(_classify_conflicts_by_pattern \
	"packages/db/migrations/meta/_journal.json" "$CONF_FILE")
assert_contains "2a: journal.json → DRIZZLE_MIGRATION" \
	"DRIZZLE_MIGRATION" "$drizzle_out"

# 2b: Drizzle snapshot
snap_out=$(_classify_conflicts_by_pattern \
	"packages/db/migrations/meta/0084_snapshot.json" "$CONF_FILE")
assert_contains "2b: snapshot.json → DRIZZLE_MIGRATION" \
	"DRIZZLE_MIGRATION" "$snap_out"

# 2c: pnpm lockfile
pnpm_out=$(_classify_conflicts_by_pattern \
	"pnpm-lock.yaml" "$CONF_FILE")
assert_contains "2c: pnpm-lock.yaml → LOCKFILE" \
	"LOCKFILE" "$pnpm_out"

# 2d: npm lockfile
npm_out=$(_classify_conflicts_by_pattern \
	"package-lock.json" "$CONF_FILE")
assert_contains "2d: package-lock.json → LOCKFILE" \
	"LOCKFILE" "$npm_out"

# 2e: yarn lockfile
yarn_out=$(_classify_conflicts_by_pattern \
	"yarn.lock" "$CONF_FILE")
assert_contains "2e: yarn.lock → LOCKFILE" \
	"LOCKFILE" "$yarn_out"

# 2f: i18n translation JSON
i18n_out=$(_classify_conflicts_by_pattern \
	"packages/i18n/src/translations/en/dashboard.json" "$CONF_FILE")
assert_contains "2f: translations/en/dashboard.json → I18N_JSON" \
	"I18N_JSON" "$i18n_out"

# 2g: generic snapshot file
gen_out=$(_classify_conflicts_by_pattern \
	"src/schema/schema_snapshot.json" "$CONF_FILE")
assert_contains "2g: *_snapshot.json → GENERATED or DRIZZLE_MIGRATION" \
	"GENERATED" "${gen_out}${drizzle_out}"  # one of the two must contain it

# 2h: source code file → CODE
code_out=$(_classify_conflicts_by_pattern \
	"packages/api/src/routes/users.ts" "$CONF_FILE")
assert_contains "2h: users.ts → CODE" \
	"CODE" "$code_out"

# 2i: empty input → empty output
empty_out=$(_classify_conflicts_by_pattern "" "$CONF_FILE")
assert_empty "2i: empty file list → empty output" "$empty_out"

echo ""

# ---------------------------------------------------------------------------
# Test 3: mixed-pattern PR — multiple classes on separate output lines.
# ---------------------------------------------------------------------------
echo "--- Section 3: mixed-pattern classification ---"

mixed_files=$(printf '%s\n' \
	"packages/db/migrations/meta/_journal.json" \
	"pnpm-lock.yaml" \
	"packages/i18n/src/translations/de/dashboard.json" \
	"packages/api/src/routes/users.ts")

mixed_out=$(_classify_conflicts_by_pattern "$mixed_files" "$CONF_FILE")

assert_contains "3a: mixed PR contains DRIZZLE_MIGRATION line" \
	"DRIZZLE_MIGRATION" "$mixed_out"
assert_contains "3b: mixed PR contains LOCKFILE line" \
	"LOCKFILE" "$mixed_out"
assert_contains "3c: mixed PR contains I18N_JSON line" \
	"I18N_JSON" "$mixed_out"
assert_contains "3d: mixed PR contains CODE line" \
	"CODE" "$mixed_out"

# Verify each class appears on its own line.
drizzle_line=$(printf '%s\n' "$mixed_out" | grep '^DRIZZLE_MIGRATION')
lockfile_line=$(printf '%s\n' "$mixed_out" | grep '^LOCKFILE')
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -n "$drizzle_line" && -n "$lockfile_line" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 3e: each class on its own line"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 3e: classes not on separate lines"
	echo "  output: $(printf '%q' "$mixed_out")"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 4: _build_conflict_feedback_section brief output.
# ---------------------------------------------------------------------------
echo "--- Section 4: _build_conflict_feedback_section brief output ---"

# 4a: With non-CODE conflict → guidance block emitted.
brief_with_pattern=$(_build_conflict_feedback_section \
	"9999" "test PR title" \
	"packages/db/migrations/meta/_journal.json" \
	"abc1234" "main" "1")
assert_contains "4a: drizzle conflict → Pattern-Specific Resolution Guidance present" \
	"### Pattern-Specific Resolution Guidance" "$brief_with_pattern"

# 4b: Drizzle guidance block contains pattern header.
assert_contains "4b: drizzle brief → 'Pattern: DRIZZLE_MIGRATION'" \
	"Pattern: DRIZZLE_MIGRATION" "$brief_with_pattern"

# 4c: Default branch placeholder substituted.
assert_not_contains "4c: {default_branch} placeholder expanded" \
	"{default_branch}" "$brief_with_pattern"
assert_contains "4c2: 'main' appears in guidance" \
	"main" "$brief_with_pattern"

# 4d: Lockfile conflict → guidance block emitted.
brief_lockfile=$(_build_conflict_feedback_section \
	"9998" "lockfile PR" \
	"pnpm-lock.yaml" \
	"def5678" "develop" "1")
assert_contains "4d: lockfile conflict → guidance block present" \
	"### Pattern-Specific Resolution Guidance" "$brief_lockfile"
assert_contains "4d2: lockfile guidance → 'Pattern: LOCKFILE'" \
	"Pattern: LOCKFILE" "$brief_lockfile"

# 4e: CODE-only conflict → NO guidance block.
brief_code_only=$(_build_conflict_feedback_section \
	"9997" "code PR" \
	"packages/api/src/routes/users.ts" \
	"fed9876" "main" "1")
assert_not_contains "4e: CODE-only conflict → no Pattern-Specific Guidance block" \
	"### Pattern-Specific Resolution Guidance" "$brief_code_only"

# 4f: i18n conflict → jq union-merge mentioned.
brief_i18n=$(_build_conflict_feedback_section \
	"9996" "i18n PR" \
	"packages/i18n/src/translations/en/dashboard.json" \
	"aaa1111" "main" "1")
assert_contains "4f: i18n conflict → guidance block present" \
	"### Pattern-Specific Resolution Guidance" "$brief_i18n"
assert_contains "4f2: i18n guidance mentions jq" \
	"jq" "$brief_i18n"

# 4g: Empty file list → no guidance block (graceful no-op).
brief_empty=$(_build_conflict_feedback_section \
	"9995" "empty PR" \
	"" \
	"bbb2222" "main" "0")
assert_not_contains "4g: empty file list → no guidance block" \
	"### Pattern-Specific Resolution Guidance" "$brief_empty"

# 4h: Mixed PR → guidance block with multiple patterns.
brief_mixed=$(_build_conflict_feedback_section \
	"9994" "mixed PR" \
	"$(printf '%s\n' packages/db/migrations/meta/_journal.json pnpm-lock.yaml packages/api/src/foo.ts)" \
	"ccc3333" "main" "3")
assert_contains "4h: mixed brief → guidance block" \
	"### Pattern-Specific Resolution Guidance" "$brief_mixed"
assert_contains "4h2: mixed brief → DRIZZLE_MIGRATION guidance" \
	"Pattern: DRIZZLE_MIGRATION" "$brief_mixed"
assert_contains "4h3: mixed brief → LOCKFILE guidance" \
	"Pattern: LOCKFILE" "$brief_mixed"

echo ""

# ---------------------------------------------------------------------------
# Test 4.5: t3199 ADD_ADD_NEW_FILE classification.
#
# Build a transient git repo, create a `add/add` rebase conflict, and verify
# _classify_conflicts_by_pattern surfaces ADD_ADD_NEW_FILE when given the
# repo path as 3rd arg.
# ---------------------------------------------------------------------------
echo "--- Section 4.5: t3199 add/add detection ---"

# Helper: build a tmp git repo with the given conflicts.
# Args: $1 = how many AA files (n), $2 = whether to also add a content
# conflict on pnpm-lock.yaml (1=yes).
_t3199_make_addadd_repo() {
	local aa_count="$1"
	local with_lockfile="$2"
	local repo
	repo=$(mktemp -d -t t3199-addadd-XXXXXX) || return 1

	(
		cd "$repo" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "Test"

		# Initial commit on main. When we want a content (UU) conflict on
		# pnpm-lock.yaml, seed it on the common ancestor so both branches
		# MODIFY it (rather than ADD it from nothing — which would be AA).
		echo "seed" >seed.txt
		git add seed.txt
		if [[ "$with_lockfile" == "1" ]]; then
			printf 'lockfileVersion: 9.0\nfromBase: seed\n' >pnpm-lock.yaml
			git add pnpm-lock.yaml
		fi
		git commit -q -m "seed"
		local seed_sha
		seed_sha=$(git rev-list --max-parents=0 HEAD)

		# Branch B (the "merged-first" branch): adds aa-N.sh files and
		# modifies pnpm-lock.yaml. Merge B into main to make it canonical.
		git checkout -q -b feat-b
		local i
		for ((i = 1; i <= aa_count; i++)); do
			printf 'echo "from B %d"\n' "$i" >"aa-${i}.sh"
			git add "aa-${i}.sh"
		done
		if [[ "$with_lockfile" == "1" ]]; then
			printf 'lockfileVersion: 9.0\nfromBranch: B\n' >pnpm-lock.yaml
			git add pnpm-lock.yaml
		fi
		git commit -q -m "feat-b: add aa files and (maybe) modify lockfile"
		git checkout -q main
		git merge -q --no-ff feat-b -m "merge feat-b"

		# Branch A (the "to-be-rebased" branch): branched off seed, adds the
		# same aa-N.sh files with different content, and (optionally) edits
		# pnpm-lock.yaml differently. Replay onto main to trigger AA on the
		# new files + UU content conflict on the seeded lockfile.
		git checkout -q -b feat-a "$seed_sha"
		for ((i = 1; i <= aa_count; i++)); do
			printf 'echo "from A %d"\n' "$i" >"aa-${i}.sh"
			git add "aa-${i}.sh"
		done
		if [[ "$with_lockfile" == "1" ]]; then
			printf 'lockfileVersion: 9.0\nfromBranch: A\n' >pnpm-lock.yaml
			git add pnpm-lock.yaml
		fi
		git commit -q -m "feat-a: add aa files and (maybe) modify lockfile"

		# Trigger rebase to produce conflicts. We expect rebase to halt with
		# AA rows on aa-N.sh and UU on pnpm-lock.yaml; that is exactly the
		# state we want to inspect.
		git rebase main >/dev/null 2>&1 || true
	)
	printf '%s\n' "$repo"
	return 0
}

# Helper: clean up tmp repo.
_t3199_rm_repo() {
	local repo="$1"
	[[ -n "$repo" && -d "$repo" ]] || return 0
	rm -rf "$repo" 2>/dev/null || true
	return 0
}

# 4.5a: single add/add conflict on a `.sh` file → ADD_ADD_NEW_FILE.
T3199_REPO_A=$(_t3199_make_addadd_repo 1 0)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -n "$T3199_REPO_A" ]] && [[ -d "$T3199_REPO_A" ]]; then
	# Sanity: confirm the rebase produced an AA row.
	aa_check=$(git -C "$T3199_REPO_A" status --porcelain 2>/dev/null \
		| awk '/^AA / {print $2}' | tr '\n' ' ')
	if [[ -n "$aa_check" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 4.5a-pre: tmp repo produced AA conflict (\`$aa_check\`)"
		# Pass the same file list the pulse would (the path of the AA file).
		t3199a_out=$(_classify_conflicts_by_pattern "aa-1.sh" "$CONF_FILE" "$T3199_REPO_A")
		assert_contains "4.5a: single add/add → ADD_ADD_NEW_FILE classification" \
			"ADD_ADD_NEW_FILE" "$t3199a_out"
		assert_not_contains "4.5a-2: add/add file NOT also classified as CODE" \
			"CODE aa-1.sh" "$t3199a_out"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 4.5a-pre: tmp repo did NOT produce AA conflict — git rebase setup likely failed; skipping 4.5a"
	fi
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 4.5a: tmp repo creation failed"
fi

# 4.5b: mixed add/add + lockfile content conflict → BOTH classifications.
T3199_REPO_B=$(_t3199_make_addadd_repo 1 1)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -n "$T3199_REPO_B" ]] && [[ -d "$T3199_REPO_B" ]]; then
	# Pass both files in the input list — pnpm-lock.yaml is NOT in AA state
	# (it's a content conflict, marked UU), so it should fall through to
	# the LOCKFILE glob bucket.
	t3199b_files=$(printf '%s\n' "aa-1.sh" "pnpm-lock.yaml")
	t3199b_out=$(_classify_conflicts_by_pattern "$t3199b_files" "$CONF_FILE" "$T3199_REPO_B")
	assert_contains "4.5b: mixed add/add + lockfile → ADD_ADD_NEW_FILE present" \
		"ADD_ADD_NEW_FILE aa-1.sh" "$t3199b_out"
	assert_contains "4.5b-2: mixed add/add + lockfile → LOCKFILE present" \
		"LOCKFILE pnpm-lock.yaml" "$t3199b_out"
	# Each class on its own line.
	addadd_line=$(printf '%s\n' "$t3199b_out" | grep '^ADD_ADD_NEW_FILE')
	lockfile_line=$(printf '%s\n' "$t3199b_out" | grep '^LOCKFILE')
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -n "$addadd_line" && -n "$lockfile_line" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 4.5b-3: ADD_ADD_NEW_FILE and LOCKFILE on separate lines"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 4.5b-3: classes not on separate lines"
		echo "  output: $(printf '%q' "$t3199b_out")"
	fi
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 4.5b: tmp repo creation failed"
fi

# 4.5c: content conflict on existing `.sh` (no AA, no repo_path) → CODE.
# Existing behaviour, unchanged: when no repo_path is supplied, the function
# never invokes `git status` and falls through to the glob loop where a
# generic .sh file matches only the CODE catch-all.
t3199c_out=$(_classify_conflicts_by_pattern "src/lib/handler.sh" "$CONF_FILE")
assert_contains "4.5c: content conflict on existing .sh → CODE (no repo_path)" \
	"CODE src/lib/handler.sh" "$t3199c_out"
assert_not_contains "4.5c-2: NO ADD_ADD_NEW_FILE classification when repo_path absent" \
	"ADD_ADD_NEW_FILE" "$t3199c_out"

# 4.5d: ADD_ADD_NEW_FILE entry exists in conf with the sentinel glob.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^ADD_ADD_NEW_FILE \| __SPECIAL_ADD_ADD__' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 4.5d: conf carries ADD_ADD_NEW_FILE entry with sentinel glob"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 4.5d: conf missing ADD_ADD_NEW_FILE/__SPECIAL_ADD_ADD__ entry"
fi

# 4.5e: _build_conflict_feedback_section emits ADD_ADD_NEW_FILE guidance
# when given a repo with an in-flight add/add. The feedback-builder doesn't
# accept a repo_path today, so we synthesise the classification by exercising
# _classify directly + _emit_pattern_guidance_blocks.
if [[ -n "${T3199_REPO_A:-}" ]] && [[ -d "${T3199_REPO_A:-}" ]]; then
	t3199e_class=$(_classify_conflicts_by_pattern "aa-1.sh" "$CONF_FILE" "$T3199_REPO_A")
	t3199e_block=$(_emit_pattern_guidance_blocks "$t3199e_class" "main" "$CONF_FILE")
	assert_contains "4.5e: ADD_ADD_NEW_FILE guidance block emitted" \
		"Pattern: ADD_ADD_NEW_FILE" "$t3199e_block"
	assert_contains "4.5e-2: guidance mentions \`--ours\` resolution" \
		"--ours" "$t3199e_block"
	assert_contains "4.5e-3: guidance warns against cherry-picking" \
		"cherry-pick" "$t3199e_block"
fi

# Cleanup.
_t3199_rm_repo "${T3199_REPO_A:-}"
_t3199_rm_repo "${T3199_REPO_B:-}"

echo ""

# ---------------------------------------------------------------------------
# Test 5: shellcheck cleanliness.
# ---------------------------------------------------------------------------
echo "--- Section 5: shellcheck ---"

TESTS_RUN=$((TESTS_RUN + 1))
if command -v shellcheck >/dev/null 2>&1; then
	sc_out=$(shellcheck "$MODULE" 2>&1)
	sc_rc=$?
	if [[ $sc_rc -eq 0 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 5a: pulse-merge-feedback.sh passes shellcheck"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 5a: shellcheck violations:"
		echo "$sc_out"
	fi
else
	echo "${TEST_GREEN}PASS${TEST_NC}: 5a: shellcheck not installed — skipping"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ===${TEST_NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
