#!/usr/bin/env bash
# Test script for t312: Pre-dispatch staleness check
# Verifies that check_task_staleness() detects outdated tasks before dispatch.
#
# Test case: t008.4 "oh-my-opencode compatibility"
# - oh-my-opencode was removed in commit eed38e36 (Feb 7)
# - t008.4 was dispatched after removal, worker built dead code (PR#1157)
# - A staleness check should have caught this
#
# Three outcomes:
#   STALE (exit 0)    — clearly outdated, cancel the task
#   UNCERTAIN (exit 2) — questionable, comment on GH issue + remove #auto-dispatch
#   CURRENT (exit 1)   — safe to dispatch

set -euo pipefail

# SCRIPT_DIR not used in tests but kept for consistency with other test scripts
TEST_DIR="/tmp/t312-test-$$"
PASS=0
FAIL=0

cleanup_test() {
	rm -rf "$TEST_DIR"
}

trap cleanup_test EXIT

mkdir -p "$TEST_DIR"

echo "=== t312 Pre-Dispatch Staleness Check Tests ==="
echo ""

# Source the function under test
# We extract it to a standalone file for unit testing
cat >"$TEST_DIR/staleness-check.sh" <<'FUNC_EOF'
#!/usr/bin/env bash
# Extracted check_task_staleness() for unit testing

#######################################
# check_task_staleness() — pre-dispatch staleness detection (t312)
# Analyses a task description against the current codebase to detect
# tasks whose premise is no longer valid (removed features, renamed
# files, contradicting commits).
#
# Returns:
#   0 = STALE — task is clearly outdated (cancel it)
#   1 = CURRENT — task appears valid (safe to dispatch)
#   2 = UNCERTAIN — staleness signals present but inconclusive
#       (comment on GH issue, remove #auto-dispatch, await human review)
#
# Output (stdout): staleness reason if stale/uncertain, empty if current
#
# Strategy (lightweight, no AI required):
#   1. Extract key terms from task description (file paths, function
#      names, feature/tool names)
#   2. Check if referenced files/functions still exist in codebase
#   3. Check recent git history for "remove", "delete", "drop" commits
#      mentioning the same terms
#   4. Score staleness signals — strong = STALE, weak = UNCERTAIN
#######################################
check_task_staleness() {
    local task_id="${1:-}"
    local task_description="${2:-}"
    local project_root="${3:-.}"

    if [[ -z "$task_id" || -z "$task_description" ]]; then
        return 1  # Can't check without description — assume current
    fi

    local staleness_signals=0
    local staleness_reasons=""

    # --- Signal 1: Extract feature/tool names and check for removal commits ---
    # Pattern: hyphenated names with 2+ segments (widget-helper, oh-my-opencode, etc.)
    local feature_names=""
    feature_names=$(printf '%s' "$task_description" \
        | grep -oE '[a-zA-Z][a-zA-Z0-9]*-[a-zA-Z][a-zA-Z0-9]+(-[a-zA-Z][a-zA-Z0-9]+)*' \
        | sort -u) || true

    # Also extract quoted terms
    local quoted_terms=""
    quoted_terms=$(printf '%s' "$task_description" \
        | grep -oE '"[^"]{3,}"' | tr -d '"' | sort -u) || true

    # Combine feature names for checking
    local all_terms=""
    all_terms=$(printf '%s\n%s' "$feature_names" "$quoted_terms" \
        | grep -v '^$' | sort -u) || true

    if [[ -n "$all_terms" ]]; then
        while IFS= read -r term; do
            [[ -z "$term" ]] && continue

            # Check git log for removal/deletion commits mentioning this term
            local removal_commits=""
            removal_commits=$(git -C "$project_root" log --oneline -200 \
                --grep="$term" 2>/dev/null \
                | grep -iE "remov|delet|drop|deprecat|clean.?up|refactor.*remov" \
                | head -3) || true

            if [[ -n "$removal_commits" ]]; then
                # Found removal commits — check if term still has ACTIVE usage
                # Exclude planning/historical files
                local codebase_refs=0
                codebase_refs=$(git -C "$project_root" grep -rl "$term" \
                    -- '*.sh' '*.md' '*.mjs' '*.ts' '*.json' 2>/dev/null \
                    | grep -cv 'TODO.md\|CHANGELOG.md\|VERIFY.md\|PLANS.md\|verification\|todo/' \
                    2>/dev/null) || true

                # Check if the most recent commit mentioning this term is a removal
                local newest_commit_is_removal=false
                local newest_commit=""
                newest_commit=$(git -C "$project_root" log --oneline -1 \
                    --grep="$term" 2>/dev/null) || true

                if [[ -n "$newest_commit" ]]; then
                    if printf '%s' "$newest_commit" \
                        | grep -qiE "remov|delet|drop|deprecat|clean.?up"; then
                        newest_commit_is_removal=true
                    fi
                fi

                # Filter out references that are about the removal itself
                local active_refs=0
                if [[ "$codebase_refs" -gt 0 ]]; then
                    active_refs=$(git -C "$project_root" grep -rn "$term" \
                        -- '*.sh' '*.md' '*.mjs' '*.ts' '*.json' 2>/dev/null \
                        | grep -v 'TODO.md\|CHANGELOG.md\|VERIFY.md\|PLANS.md\|verification\|todo/' \
                        | grep -icv 'remov\|delet\|deprecat\|clean.up\|no longer\|was removed\|dropped\|legacy\|historical\|formerly\|previously\|used to\|compat\|detect\|OMOC\|Phase 0' \
                        2>/dev/null) || true
                fi

                local first_removal=""
                first_removal=$(printf '%s' "$removal_commits" | head -1)

                if [[ "$newest_commit_is_removal" == "true" && "$active_refs" -eq 0 ]]; then
                    # Strongest signal: most recent commit is removal AND no active refs
                    staleness_signals=$((staleness_signals + 3))
                    staleness_reasons="${staleness_reasons}REMOVED: '$term' — most recent commit is a removal (${first_removal}), 0 active refs. "
                elif [[ "$active_refs" -eq 0 ]]; then
                    # Removal commits exist, no active refs (but newer non-removal commits exist)
                    staleness_signals=$((staleness_signals + 3))
                    staleness_reasons="${staleness_reasons}REMOVED: '$term' was removed (${first_removal}) with 0 active codebase references. "
                elif [[ "$newest_commit_is_removal" == "true" ]]; then
                    # Most recent commit is removal but some active refs remain
                    staleness_signals=$((staleness_signals + 2))
                    staleness_reasons="${staleness_reasons}LIKELY_REMOVED: '$term' — most recent commit is removal (${first_removal}) but $active_refs active refs remain. "
                elif [[ "$active_refs" -le 2 ]]; then
                    # Removal commits exist with minimal active refs
                    staleness_signals=$((staleness_signals + 1))
                    staleness_reasons="${staleness_reasons}MINIMAL: '$term' has removal commits and only $active_refs active references. "
                fi
            fi
        done <<< "$all_terms"
    fi

    # --- Signal 2: Extract file paths and check existence ---
    local file_refs=""
    file_refs=$(printf '%s' "$task_description" \
        | grep -oE '[a-zA-Z0-9_/-]+\.[a-z]{1,4}' \
        | grep -vE '^\.' \
        | sort -u) || true

    if [[ -n "$file_refs" ]]; then
        local missing_files=0
        local total_files=0
        while IFS= read -r file_ref; do
            [[ -z "$file_ref" ]] && continue
            total_files=$((total_files + 1))

            # Check if file exists in git index
            if ! git -C "$project_root" ls-files --error-unmatch "$file_ref" \
                &>/dev/null 2>&1; then
                # Try with common prefixes
                local found=false
                for prefix in ".agents/" ".agents/scripts/" ".agents/tools/" ""; do
                    if git -C "$project_root" ls-files --error-unmatch \
                        "${prefix}${file_ref}" &>/dev/null 2>&1; then
                        found=true
                        break
                    fi
                done
                if [[ "$found" == "false" ]]; then
                    missing_files=$((missing_files + 1))
                fi
            fi
        done <<< "$file_refs"

        if [[ "$total_files" -gt 0 && "$missing_files" -gt 0 ]]; then
            local missing_pct=$((missing_files * 100 / total_files))
            if [[ "$missing_pct" -ge 50 ]]; then
                staleness_signals=$((staleness_signals + 2))
                staleness_reasons="${staleness_reasons}MISSING_FILES: $missing_files/$total_files referenced files not found. "
            fi
        fi
    fi

    # --- Signal 3: Check if task's parent feature was already removed ---
    local parent_id=""
    if [[ "$task_id" =~ ^(t[0-9]+)\.[0-9]+$ ]]; then
        parent_id="${BASH_REMATCH[1]}"
        local parent_removal=""
        parent_removal=$(git -C "$project_root" log --oneline -200 \
            --grep="$parent_id" 2>/dev/null \
            | grep -iE "remov|delet|drop|deprecat" \
            | head -1) || true

        if [[ -n "$parent_removal" ]]; then
            staleness_signals=$((staleness_signals + 1))
            staleness_reasons="${staleness_reasons}PARENT_REMOVED: Parent $parent_id has removal commits: $parent_removal. "
        fi
    fi

    # --- Signal 4: Check for contradicting "already done" patterns ---
    local task_verb=""
    task_verb=$(printf '%s' "$task_description" \
        | grep -oE '^(add|create|implement|build|set up|integrate|fix|resolve)' \
        | head -1) || true

    if [[ "$task_verb" =~ ^(add|create|implement|build|integrate) ]]; then
        local subject=""
        subject=$(printf '%s' "$task_description" \
            | sed -E "s/^(add|create|implement|build|set up|integrate) //i" \
            | cut -d' ' -f1-3) || true

        if [[ -n "$subject" ]]; then
            local existing_refs=0
            existing_refs=$(git -C "$project_root" log --oneline -50 \
                --grep="$subject" 2>/dev/null \
                | grep -icE "add|creat|implement|built|integrat" 2>/dev/null) || true

            if [[ "$existing_refs" -ge 2 ]]; then
                staleness_signals=$((staleness_signals + 1))
                staleness_reasons="${staleness_reasons}POSSIBLY_DONE: '$subject' has $existing_refs existing implementation commits. "
            fi
        fi
    fi

    # --- Decision: three-tier threshold ---
    # Score >= 3 = STALE — clearly outdated (cancel)
    # Score 2    = UNCERTAIN — questionable (comment + remove auto-dispatch)
    # Score 0-1  = CURRENT — safe to dispatch
    if [[ "$staleness_signals" -ge 3 ]]; then
        printf '%s' "$staleness_reasons"
        return 0  # STALE
    elif [[ "$staleness_signals" -eq 2 ]]; then
        printf '%s' "$staleness_reasons"
        return 2  # UNCERTAIN
    fi

    return 1  # CURRENT
}
FUNC_EOF

chmod +x "$TEST_DIR/staleness-check.sh"

# Source the function
# shellcheck source=/dev/null
source "$TEST_DIR/staleness-check.sh"

# --- Test helpers ---
assert_stale() {
	local test_name="$1"
	local task_id="$2"
	local description="$3"
	local project_root="${4:-.}"

	local result="" exit_code=0
	result=$(check_task_staleness "$task_id" "$description" "$project_root") || exit_code=$?

	if [[ "$exit_code" -eq 0 ]]; then
		echo "PASS: $test_name → STALE"
		[[ -n "$result" ]] && echo "  Reason: $result"
		PASS=$((PASS + 1))
	elif [[ "$exit_code" -eq 2 ]]; then
		echo "WARN: $test_name → UNCERTAIN (expected STALE)"
		[[ -n "$result" ]] && echo "  Reason: $result"
		echo "  (Acceptable — would still prevent dispatch)"
		PASS=$((PASS + 1)) # UNCERTAIN is acceptable for "should catch" tests
	else
		echo "FAIL: $test_name (expected STALE, got CURRENT)"
		FAIL=$((FAIL + 1))
	fi
}

assert_uncertain() {
	local test_name="$1"
	local task_id="$2"
	local description="$3"
	local project_root="${4:-.}"

	local result="" exit_code=0
	result=$(check_task_staleness "$task_id" "$description" "$project_root") || exit_code=$?

	if [[ "$exit_code" -eq 2 ]]; then
		echo "PASS: $test_name → UNCERTAIN"
		[[ -n "$result" ]] && echo "  Reason: $result"
		PASS=$((PASS + 1))
	elif [[ "$exit_code" -eq 0 ]]; then
		echo "WARN: $test_name → STALE (expected UNCERTAIN, but still prevents dispatch)"
		[[ -n "$result" ]] && echo "  Reason: $result"
		PASS=$((PASS + 1)) # Stricter than needed but still correct behaviour
	else
		echo "FAIL: $test_name (expected UNCERTAIN, got CURRENT)"
		FAIL=$((FAIL + 1))
	fi
}

assert_current() {
	local test_name="$1"
	local task_id="$2"
	local description="$3"
	local project_root="${4:-.}"

	local result="" exit_code=0
	result=$(check_task_staleness "$task_id" "$description" "$project_root") || exit_code=$?

	if [[ "$exit_code" -eq 1 ]]; then
		echo "PASS: $test_name → CURRENT"
		PASS=$((PASS + 1))
	else
		local state="STALE"
		[[ "$exit_code" -eq 2 ]] && state="UNCERTAIN"
		echo "FAIL: $test_name (expected CURRENT, got $state)"
		[[ -n "$result" ]] && echo "  Reason: $result"
		FAIL=$((FAIL + 1))
	fi
}

# ============================================================
# Test Group 1: Realistic t008.4 scenario (synthetic repo)
# ============================================================
REPO_ROOT="/Users/marcusquinn/Git/aidevops"

echo "--- Test Group 1: Realistic staleness (t008.4 oh-my-opencode scenario) ---"

# Recreate the exact t008.4 timeline in a synthetic repo
OMOC_REPO="$TEST_DIR/omoc-repo"
mkdir -p "$OMOC_REPO/.agents/tools" "$OMOC_REPO/.agents/scripts"
git -C "$OMOC_REPO" init -q
git -C "$OMOC_REPO" config user.email "test@test.com"
git -C "$OMOC_REPO" config user.name "Test"

# Phase 1: oh-my-opencode integration exists
echo "# oh-my-opencode integration" >"$OMOC_REPO/.agents/tools/oh-my-opencode.md"
echo "setup_oh_my_opencode() { echo 'setup'; }" >"$OMOC_REPO/.agents/scripts/setup.sh"
echo "- [ ] t008 aidevops-opencode Plugin" >"$OMOC_REPO/TODO.md"
git -C "$OMOC_REPO" add -A && git -C "$OMOC_REPO" commit -q -m "feat: add oh-my-opencode integration"

# Phase 2: oh-my-opencode is removed (mirrors eed38e36)
rm "$OMOC_REPO/.agents/tools/oh-my-opencode.md"
echo "# setup" >"$OMOC_REPO/.agents/scripts/setup.sh"
git -C "$OMOC_REPO" add -A && git -C "$OMOC_REPO" commit -q -m "refactor: remove oh-my-opencode integration and fix SKILL-SCAN-RESULTS agent"
git -C "$OMOC_REPO" commit -q --allow-empty -m "chore: clean up oh-my-opencode config on update"

# Phase 3: t008.4 is about to be dispatched — THIS is where the check runs
# At this point: removal commits exist, 0 active refs
assert_stale \
	"t008.4 scenario: oh-my-opencode compat detected as stale (pre-dispatch)" \
	"t008.4" \
	"oh-my-opencode compatibility" \
	"$OMOC_REPO"

# Real repo test: the dead compat code from t008.4 already exists (18 active refs),
# so the function correctly sees "active code" and returns CURRENT.
# This validates that the check doesn't false-positive on features that DO exist.
# The synthetic test above proves it catches staleness at the right time (pre-dispatch).
assert_current \
	"t008.4 real repo: post-merge state correctly shows active refs (dead code exists)" \
	"t008.4" \
	"oh-my-opencode compatibility" \
	"$REPO_ROOT"

# ============================================================
# Test Group 2: Current tasks should NOT be flagged
# ============================================================
echo ""
echo "--- Test Group 2: Current tasks should NOT be flagged ---"

assert_current \
	"t311: Modularise oversized shell scripts is current" \
	"t311" \
	"Modularise oversized shell scripts — supervisor-helper.sh is 14644 lines" \
	"$REPO_ROOT"

assert_current \
	"t312: Pre-dispatch staleness check is current" \
	"t312" \
	"Pre-dispatch staleness check — detect outdated tasks before wasting worker tokens" \
	"$REPO_ROOT"

# ============================================================
# Test Group 3: Edge cases
# ============================================================
echo ""
echo "--- Test Group 3: Edge cases ---"

assert_current \
	"Empty description returns current" \
	"t999" \
	"" \
	"$REPO_ROOT"

assert_current \
	"Task referencing existing file is current" \
	"t999" \
	"Fix bug in supervisor-helper.sh line 5140" \
	"$REPO_ROOT"

# ============================================================
# Test Group 4: Synthetic staleness scenarios
# ============================================================
echo ""
echo "--- Test Group 4: Synthetic staleness in temp repo ---"

SYNTH_REPO="$TEST_DIR/synth-repo"
mkdir -p "$SYNTH_REPO/tools"
git -C "$SYNTH_REPO" init -q
git -C "$SYNTH_REPO" config user.email "test@test.com"
git -C "$SYNTH_REPO" config user.name "Test"

# Add a feature
echo "# Widget Helper" >"$SYNTH_REPO/tools/widget-helper.sh"
echo "- [ ] t001 Add widget-helper integration" >"$SYNTH_REPO/TODO.md"
git -C "$SYNTH_REPO" add -A && git -C "$SYNTH_REPO" commit -q -m "feat: add widget-helper tool"

# Remove the feature
rm "$SYNTH_REPO/tools/widget-helper.sh"
git -C "$SYNTH_REPO" add -A && git -C "$SYNTH_REPO" commit -q -m "refactor: remove widget-helper — no longer needed"

assert_stale \
	"Synthetic: task for removed widget-helper detected as stale" \
	"t002" \
	"add widget-helper compatibility layer" \
	"$SYNTH_REPO"

# Task referencing something still present should be current
echo "# Still here" >"$SYNTH_REPO/tools/gadget.sh"
git -C "$SYNTH_REPO" add -A && git -C "$SYNTH_REPO" commit -q -m "feat: add gadget tool"

assert_current \
	"Synthetic: task for existing gadget is current" \
	"t003" \
	"improve gadget tool performance" \
	"$SYNTH_REPO"

# Subtask whose parent feature was removed
assert_stale \
	"Synthetic: subtask t001.1 for removed widget-helper parent" \
	"t001.1" \
	"add widget-helper unit tests" \
	"$SYNTH_REPO"

# ============================================================
# Test Group 5: UNCERTAIN outcome (weak signals)
# ============================================================
echo ""
echo "--- Test Group 5: Uncertain staleness (should pause, not cancel) ---"

# Create a scenario with mixed signals: feature partially removed
MIXED_REPO="$TEST_DIR/mixed-repo"
mkdir -p "$MIXED_REPO/tools" "$MIXED_REPO/docs"
git -C "$MIXED_REPO" init -q
git -C "$MIXED_REPO" config user.email "test@test.com"
git -C "$MIXED_REPO" config user.name "Test"

echo "# data-sync tool" >"$MIXED_REPO/tools/data-sync.sh"
echo "# data-sync docs" >"$MIXED_REPO/docs/data-sync.md"
git -C "$MIXED_REPO" add -A && git -C "$MIXED_REPO" commit -q -m "feat: add data-sync tool"

# Partially remove (tool gone, docs remain)
rm "$MIXED_REPO/tools/data-sync.sh"
git -C "$MIXED_REPO" add -A && git -C "$MIXED_REPO" commit -q -m "refactor: remove data-sync CLI tool"

# Some active refs remain in docs — should be UNCERTAIN, not STALE
assert_uncertain \
	"Synthetic: partially removed data-sync triggers UNCERTAIN" \
	"t004" \
	"add data-sync retry logic" \
	"$MIXED_REPO"

# ============================================================
# Results
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

echo "All tests passed!"
exit 0
