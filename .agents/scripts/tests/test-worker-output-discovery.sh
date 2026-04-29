#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-output-discovery.sh — Regression tests for the worktree-discovery
# logic added to `_worker_produced_output` by t2982 (GH#21354).
#
# Background (Mode B/C worker misclassification)
# -----------------------------------------------
# Before t2982, `_worker_produced_output` read HEAD from `work_dir`, which is
# captured once at dispatch time and never updated. Two cases produced wrong
# classifications:
#
#   Mode B: worker creates its own worktree (e.g. bugfix/gh-99999-something)
#           and does all work there. At EXIT, work_dir still points at the
#           dispatch worktree on main → branch_name = "main" → noop.
#
#   Mode C: worker merges its PR and exits back on the default branch. Same
#           symptom: branch_name = "main" → noop.
#
# The fix: before reading HEAD, scan `git worktree list --porcelain` for a
# worktree whose branch ref contains `gh-?<WORKER_ISSUE_NUMBER>`. If found,
# use that path (actual_dir) for the branch_name read.
#
# Cases tested here
# -----------------
#   1. Work done in a separate worktree (Mode B simulation):
#      WORKER_ISSUE_NUMBER=99999, work_dir on main, feature worktree on
#      bugfix/gh-99999-fix → branch_name should be "bugfix/gh-99999-fix",
#      not "main". Expected: pr_exists (PR count stub = 1).
#
#   2. WORKER_ISSUE_NUMBER unset (non-issue worker / backward compat):
#      work_dir on main with no feature worktree → falls back to work_dir.
#      Expected: noop (no commits, no pushed branch).
#
#   3. WORKER_ISSUE_NUMBER set but no matching worktree exists:
#      Falls back to work_dir behaviour.
#      Expected: noop (no commits, no pushed branch in work_dir).
#
#   4. gh-hyphen variant: worktree branch uses gh-99999 (with hyphen).
#      Expected: discovery succeeds, pr_exists (PR count stub = 1).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
HELPER_SCRIPT="${TEST_SCRIPTS_DIR}/headless-runtime-helper.sh"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s%s\n' "$TEST_RED" "$TEST_RESET" "$name" "${extra:+ — $extra}"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Sandbox setup
# -----------------------------------------------------------------------------

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

ORIGINAL_HOME="$HOME"
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# Stub `gh` to return a controllable PR-list count without touching the network.
GH_STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$GH_STUB_DIR"
cat >"${GH_STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: `gh pr list ... --jq 'length'` returns ${STUB_PR_COUNT:-0}.
# Other invocations exit 0 silently so sourced helpers don't crash the test.
case "${1:-}" in
	pr)
		case "${2:-}" in
			list) printf '%s\n' "${STUB_PR_COUNT:-0}" ;;
			*) ;;
		esac
		;;
	api)
		printf '{}\n'
		;;
	*) ;;
esac
exit 0
STUB
chmod +x "${GH_STUB_DIR}/gh"
export PATH="${GH_STUB_DIR}:${PATH}"

# Source the helper. Disable set -e while sourcing so transient auth checks
# (gh api user, etc.) don't abort.
set +e
# shellcheck source=/dev/null
source "$HELPER_SCRIPT" >/dev/null 2>&1
SOURCE_RC=$?
set -e
if [[ "$SOURCE_RC" -ne 0 ]]; then
	if ! declare -F _worker_produced_output >/dev/null 2>&1; then
		printf '%sFAIL%s sourcing %s — _worker_produced_output not defined\n' \
			"$TEST_RED" "$TEST_RESET" "$HELPER_SCRIPT"
		exit 1
	fi
fi

if ! declare -F _worker_produced_output >/dev/null 2>&1; then
	printf '%sFAIL%s _worker_produced_output not defined after source\n' \
		"$TEST_RED" "$TEST_RESET"
	exit 1
fi

# Always set DISPATCH_REPO_SLUG so Signal 3 fires (otherwise fail-open to pr_exists).
export DISPATCH_REPO_SLUG="owner/repo"

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# make_repo_pair <label>
# Creates ORIGIN_DIR (non-bare repo serving as origin) and MAIN_WORK_DIR
# (a clone on main). Sets globals ORIGIN_DIR / MAIN_WORK_DIR.
make_repo_pair() {
	local label="$1"
	ORIGIN_DIR="${TEST_ROOT}/origin-${label}"
	MAIN_WORK_DIR="${TEST_ROOT}/main-work-${label}"
	rm -rf "$ORIGIN_DIR" "$MAIN_WORK_DIR"
	mkdir -p "$ORIGIN_DIR"
	(
		cd "$ORIGIN_DIR" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "Test"
		git commit --allow-empty -q -m "init"
	) || return 1
	git clone -q "$ORIGIN_DIR" "$MAIN_WORK_DIR" || return 1
	git -C "$MAIN_WORK_DIR" config user.email "test@example.com"
	git -C "$MAIN_WORK_DIR" config user.name "Test"
	git -C "$MAIN_WORK_DIR" remote set-head origin main >/dev/null 2>&1 || true
	return 0
}

# add_feature_worktree <main_work_dir> <worktree_path> <branch_name>
# Adds a linked worktree at <worktree_path> on a new branch <branch_name>,
# creates one commit and pushes the branch to origin.
add_feature_worktree() {
	local main_dir="$1"
	local wt_path="$2"
	local branch="$3"
	git -C "$main_dir" worktree add -b "$branch" "$wt_path" 2>/dev/null || return 1
	git -C "$wt_path" config user.email "test@example.com"
	git -C "$wt_path" config user.name "Test"
	(
		cd "$wt_path" || exit 1
		printf 'change\n' >change.txt
		git add change.txt
		git commit -q -m "feature commit on $branch"
		git push -q origin "$branch"
	) || return 1
	return 0
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

test_mode_b_discovery_finds_feature_worktree() {
	make_repo_pair "modeb" || {
		print_result "case 1 (Mode B): work_dir=main, feature worktree matches issue → pr_exists" \
			1 "fixture setup failed"
		return 0
	}
	local feature_wt="${TEST_ROOT}/feature-modeb"
	add_feature_worktree "$MAIN_WORK_DIR" "$feature_wt" "bugfix/gh99999-mode-b" || {
		print_result "case 1 (Mode B): work_dir=main, feature worktree matches issue → pr_exists" \
			1 "feature worktree setup failed"
		return 0
	}
	export WORKER_ISSUE_NUMBER="99999"
	export STUB_PR_COUNT=1
	local got
	got=$(_worker_produced_output "issue-99999" "$MAIN_WORK_DIR")
	unset WORKER_ISSUE_NUMBER
	if [[ "$got" == "pr_exists" ]]; then
		print_result "case 1 (Mode B): work_dir=main, feature worktree matches issue → pr_exists" 0
	else
		print_result "case 1 (Mode B): work_dir=main, feature worktree matches issue → pr_exists" \
			1 "got: $got (expected pr_exists — discovery should find bugfix/gh99999-mode-b)"
	fi
	return 0
}

test_no_worker_issue_number_falls_back_to_work_dir() {
	make_repo_pair "fallback" || {
		print_result "case 2 (fallback): WORKER_ISSUE_NUMBER unset → work_dir behaviour (noop)" \
			1 "fixture setup failed"
		return 0
	}
	unset WORKER_ISSUE_NUMBER 2>/dev/null || true
	export STUB_PR_COUNT=0
	local got
	got=$(_worker_produced_output "issue-99999" "$MAIN_WORK_DIR")
	if [[ "$got" == "noop" ]]; then
		print_result "case 2 (fallback): WORKER_ISSUE_NUMBER unset → work_dir behaviour (noop)" 0
	else
		print_result "case 2 (fallback): WORKER_ISSUE_NUMBER unset → work_dir behaviour (noop)" \
			1 "got: $got (expected noop — no commits/branch in work_dir)"
	fi
	return 0
}

test_no_matching_worktree_falls_back_to_work_dir() {
	make_repo_pair "nomatch" || {
		print_result "case 3 (no match): WORKER_ISSUE_NUMBER set but no matching worktree → noop" \
			1 "fixture setup failed"
		return 0
	}
	# Add a worktree for a DIFFERENT issue number so there's no match for 99999.
	local other_wt="${TEST_ROOT}/other-nomatch"
	add_feature_worktree "$MAIN_WORK_DIR" "$other_wt" "bugfix/gh88888-other" || {
		print_result "case 3 (no match): WORKER_ISSUE_NUMBER set but no matching worktree → noop" \
			1 "other worktree setup failed"
		return 0
	}
	export WORKER_ISSUE_NUMBER="99999"
	export STUB_PR_COUNT=0
	local got
	got=$(_worker_produced_output "issue-99999" "$MAIN_WORK_DIR")
	unset WORKER_ISSUE_NUMBER
	if [[ "$got" == "noop" ]]; then
		print_result "case 3 (no match): WORKER_ISSUE_NUMBER set but no matching worktree → noop" 0
	else
		print_result "case 3 (no match): WORKER_ISSUE_NUMBER set but no matching worktree → noop" \
			1 "got: $got (expected noop — no gh99999 worktree, falls back to work_dir/main)"
	fi
	return 0
}

test_hyphen_variant_discovery() {
	make_repo_pair "hyphen" || {
		print_result "case 4 (hyphen): branch uses gh-99999 (with hyphen) → pr_exists" \
			1 "fixture setup failed"
		return 0
	}
	local feature_wt="${TEST_ROOT}/feature-hyphen"
	add_feature_worktree "$MAIN_WORK_DIR" "$feature_wt" "feature/auto-gh-99999-some-fix" || {
		print_result "case 4 (hyphen): branch uses gh-99999 (with hyphen) → pr_exists" \
			1 "feature worktree setup failed"
		return 0
	}
	export WORKER_ISSUE_NUMBER="99999"
	export STUB_PR_COUNT=1
	local got
	got=$(_worker_produced_output "issue-99999" "$MAIN_WORK_DIR")
	unset WORKER_ISSUE_NUMBER
	if [[ "$got" == "pr_exists" ]]; then
		print_result "case 4 (hyphen): branch uses gh-99999 (with hyphen) → pr_exists" 0
	else
		print_result "case 4 (hyphen): branch uses gh-99999 (with hyphen) → pr_exists" \
			1 "got: $got (expected pr_exists — discovery should find feature/auto-gh-99999-some-fix)"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

test_mode_b_discovery_finds_feature_worktree
test_no_worker_issue_number_falls_back_to_work_dir
test_no_matching_worktree_falls_back_to_work_dir
test_hyphen_variant_discovery

printf '\nRan %d test(s), %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

export HOME="$ORIGINAL_HOME"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
