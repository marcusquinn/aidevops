#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-output-classification.sh — Regression tests for
# `_worker_produced_output` in headless-runtime-helper.sh (t2899).
#
# Background: workers were misclassified as `worker_branch_orphan` when their
# final HEAD ended up on the default branch (main). Signal 2 of the
# classifier ("branch pushed to remote") ALWAYS matched on main because main
# exists on origin — so any worker that exited on main with no feature
# branch and no PR got reclassified as an orphan and its output discarded.
#
# This test pins the four canonical classification outcomes against the
# default-branch guard so the next regression in this hot path is caught
# before it reaches production.
#
# Cases (all share: session_key=issue-NNN, work_dir is a synthetic git repo
# with origin set, gh stubbed):
#
#   1. branch=main, ahead=0, no PR → noop
#      (Worker exited on main with nothing to ship.)
#
#   2. branch=main, ahead=N, no PR → noop  [default-branch guard, t2899]
#      (Worker landed on main with local commits but no feature branch.
#      Pre-fix behaviour: branch_orphan. Post-fix: noop, because there is
#      no orphan branch — Signal 2 must NOT fire on the default branch.)
#
#   3. branch=feature/tNNN-foo, ahead=N, no PR → branch_orphan
#      (Legitimate orphan: feature branch pushed but no PR opened. This is
#      the case the orphan-recovery PR machinery was designed for and must
#      survive the t2899 guard untouched.)
#
#   4. branch=feature/tNNN-foo, ahead=N, PR exists → pr_exists
#      (Normal worker completion. Signal 3 short-circuits to pr_exists.)
#
#   5. branch=main, ahead=N, PR exists → continued failure
#      (Failure recovery must not treat a PR match on the default branch as
#      recoverable worker output.)
#
#   6. branch=feature/tNNN-foo, no origin/HEAD/main/master, no PR → branch_orphan
#      (The default-branch resolver must not fall back to the current checkout
#      and mistake the feature branch for the default branch.)
#
# `gh` is stubbed via PATH to return a controllable PR-list count without
# touching the network. `git` is real — each case spins up its own
# disposable origin+clone pair so the classifier sees authentic refs.

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

# Stub `gh`. The classifier's Signal 3 calls:
#   gh pr list --repo <slug> --search <issue> --json number --jq 'length'
# We control the returned count via STUB_PR_COUNT (default 0).
GH_STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$GH_STUB_DIR"
cat >"${GH_STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: `gh pr list ... --jq 'length'` returns ${STUB_PR_COUNT:-0}.
# `_worker_external_terminal_complete` uses `gh issue view ... --jq state` and
# `gh pr list ... --jq '.[].number'`; those are controlled by STUB_* env vars.
# Other invocations exit 0 silently so source-time `gh api user` calls
# from sourced helpers don't crash the test.
if [[ -n "${STUB_GH_LOG:-}" ]]; then
	printf '%s\n' "$*" >>"$STUB_GH_LOG"
fi
case "${1:-}" in
	issue)
		case "${2:-}" in
			view) printf '%s\n' "${STUB_ISSUE_STATE:-OPEN}" ;;
			*) ;;
		esac
		;;
	pr)
		case "${2:-}" in
			list)
				case " $* " in
					*".[].number"*) printf '%s\n' "${STUB_PR_NUMBERS:-}" ;;
					*) printf '%s\n' "${STUB_PR_COUNT:-0}" ;;
				esac
				;;
			*) ;;
		esac
		;;
	api)
		# `_gh_wrapper_auto_sig` and friends call `gh api user --jq .login`.
		# Emit a JSON object so callers that consume stdout don't break.
		printf '{}\n'
		;;
	*) ;;
esac
exit 0
STUB
chmod +x "${GH_STUB_DIR}/gh"
export PATH="${GH_STUB_DIR}:${PATH}"

# Source the helper. set -e is disabled while sourcing so transient command
# failures (auth checks, optional helper presence) don't abort the test.
set +e
# shellcheck source=/dev/null
source "$HELPER_SCRIPT" >/dev/null 2>&1
SOURCE_RC=$?
set -e
if [[ "$SOURCE_RC" -ne 0 ]]; then
	# Soft-fail: many test machines lack the runtime deps the helper sources.
	# The function under test is self-contained — try to source again with
	# errors visible if the function itself is unreachable.
	if ! declare -F _worker_produced_output >/dev/null 2>&1; then
		printf '%sFAIL%s sourcing %s — _worker_produced_output not defined\n' \
			"$TEST_RED" "$TEST_RESET" "$HELPER_SCRIPT"
		exit 1
	fi
fi

# Confirm function is now reachable.
if ! declare -F _worker_produced_output >/dev/null 2>&1; then
	printf '%sFAIL%s _worker_produced_output not defined after source\n' \
		"$TEST_RED" "$TEST_RESET"
	exit 1
fi

# -----------------------------------------------------------------------------
# Synthetic git fixture
# -----------------------------------------------------------------------------

# make_repo_pair <label>
# Creates ORIGIN_DIR (non-bare repo serving as origin) and WORK_DIR (a clone
# of origin) with one initial commit on `main`. Sets ORIGIN_DIR / WORK_DIR
# globals so callers can manipulate them.
make_repo_pair() {
	local label="$1"
	ORIGIN_DIR="${TEST_ROOT}/origin-${label}"
	WORK_DIR="${TEST_ROOT}/work-${label}"
	rm -rf "$ORIGIN_DIR" "$WORK_DIR"
	mkdir -p "$ORIGIN_DIR"
	(
		cd "$ORIGIN_DIR" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "Test"
		git commit --allow-empty -q -m "init"
	) || return 1
	git clone -q "$ORIGIN_DIR" "$WORK_DIR" || return 1
	git -C "$WORK_DIR" config user.email "test@example.com"
	git -C "$WORK_DIR" config user.name "Test"
	# Push origin/HEAD so symbolic-ref refs/remotes/origin/HEAD resolves.
	git -C "$WORK_DIR" remote set-head origin main >/dev/null 2>&1 || true
	return 0
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

# Always set DISPATCH_REPO_SLUG so Signal 3 fires (without it the function
# fail-opens to pr_exists).
export DISPATCH_REPO_SLUG="owner/repo"

test_main_no_commits_no_pr_returns_noop() {
	make_repo_pair "case1" || {
		print_result "case 1: branch=main, ahead=0, no PR → noop" 1 "fixture setup failed"
		return 0
	}
	export STUB_PR_COUNT=0
	local got
	got=$(_worker_produced_output "issue-1001" "$WORK_DIR")
	if [[ "$got" == "noop" ]]; then
		print_result "case 1: branch=main, ahead=0, no PR → noop" 0
	else
		print_result "case 1: branch=main, ahead=0, no PR → noop" 1 "got: $got"
	fi
	return 0
}

test_main_with_local_commits_no_pr_returns_noop_t2899() {
	make_repo_pair "case2" || {
		print_result "case 2: branch=main, ahead=N, no PR → noop (default-branch guard)" 1 "fixture setup failed"
		return 0
	}
	# Add local commits on main WITHOUT pushing — pre-fix this misclassified
	# as branch_orphan because Signal 2 (origin has main) always matched.
	(
		cd "$WORK_DIR" || exit 1
		echo "local change" > local.txt
		git add local.txt
		git commit -q -m "local commit on main"
		echo "local change 2" > local2.txt
		git add local2.txt
		git commit -q -m "another local commit on main"
	) || {
		print_result "case 2: branch=main, ahead=N, no PR → noop (default-branch guard)" 1 "commit setup failed"
		return 0
	}
	export STUB_PR_COUNT=0
	local got
	got=$(_worker_produced_output "issue-1002" "$WORK_DIR")
	if [[ "$got" == "noop" ]]; then
		print_result "case 2: branch=main, ahead=N, no PR → noop (default-branch guard)" 0
	else
		print_result "case 2: branch=main, ahead=N, no PR → noop (default-branch guard)" 1 "got: $got (expected noop — default-branch guard)"
	fi
	return 0
}

test_feature_branch_pushed_no_pr_returns_branch_orphan() {
	make_repo_pair "case3" || {
		print_result "case 3: branch=feature/tNNN-foo, ahead=N, no PR → branch_orphan" 1 "fixture setup failed"
		return 0
	}
	# Create a feature branch, commit, push.
	(
		cd "$WORK_DIR" || exit 1
		git checkout -q -b feature/t9999-orphan
		echo "feature change" > feature.txt
		git add feature.txt
		git commit -q -m "feature commit"
		git push -q origin feature/t9999-orphan
	) || {
		print_result "case 3: branch=feature/tNNN-foo, ahead=N, no PR → branch_orphan" 1 "feature branch setup failed"
		return 0
	}
	export STUB_PR_COUNT=0
	local got
	got=$(_worker_produced_output "issue-1003" "$WORK_DIR")
	if [[ "$got" == "branch_orphan" ]]; then
		print_result "case 3: branch=feature/tNNN-foo, ahead=N, no PR → branch_orphan" 0
	else
		print_result "case 3: branch=feature/tNNN-foo, ahead=N, no PR → branch_orphan" 1 "got: $got"
	fi
	return 0
}

test_feature_branch_with_pr_returns_pr_exists() {
	make_repo_pair "case4" || {
		print_result "case 4: branch=feature/tNNN-foo, ahead=N, PR exists → pr_exists" 1 "fixture setup failed"
		return 0
	}
	(
		cd "$WORK_DIR" || exit 1
		git checkout -q -b feature/t9999-with-pr
		echo "feature change" > feature.txt
		git add feature.txt
		git commit -q -m "feature commit"
		git push -q origin feature/t9999-with-pr
	) || {
		print_result "case 4: branch=feature/tNNN-foo, ahead=N, PR exists → pr_exists" 1 "feature branch setup failed"
		return 0
	}
	export STUB_PR_COUNT=1
	local got
	got=$(_worker_produced_output "issue-1004" "$WORK_DIR")
	if [[ "$got" == "pr_exists" ]]; then
		print_result "case 4: branch=feature/tNNN-foo, ahead=N, PR exists → pr_exists" 0
	else
		print_result "case 4: branch=feature/tNNN-foo, ahead=N, PR exists → pr_exists" 1 "got: $got"
	fi
	return 0
}

test_failure_recovery_ignores_default_branch_pr_match() {
	make_repo_pair "case5" || {
		print_result "case 5: failure recovery ignores default branch PR match" 1 "fixture setup failed"
		return 0
	}
	(
		cd "$WORK_DIR" || exit 1
		printf '%s\n' "local change" > local.txt
		git add local.txt
		git commit -q -m "local commit on main"
	) || {
		print_result "case 5: failure recovery ignores default branch PR match" 1 "commit setup failed"
		return 0
	}
	export STUB_PR_COUNT=1
	local got="recovered"
	if _recover_worker_output_on_failure "issue-1005" "$WORK_DIR" >/dev/null 2>&1; then
		got="recovered"
	else
		got="continued_failure"
	fi
	if [[ "$got" == "continued_failure" ]]; then
		print_result "case 5: failure recovery ignores default branch PR match" 0
	else
		print_result "case 5: failure recovery ignores default branch PR match" 1 "got: $got (expected continued_failure)"
	fi
	return 0
}

test_feature_branch_without_default_ref_returns_branch_orphan() {
	ORIGIN_DIR="${TEST_ROOT}/origin-case6"
	WORK_DIR="${TEST_ROOT}/work-case6"
	rm -rf "$ORIGIN_DIR" "$WORK_DIR"
	mkdir -p "$ORIGIN_DIR"
	(
		cd "$ORIGIN_DIR" || exit 1
		git init -q -b develop
		git config user.email "test@example.com"
		git config user.name "Test"
		git commit --allow-empty -q -m "init"
	) || {
		print_result "case 6: branch=feature, no default ref, no PR → branch_orphan" 1 "origin setup failed"
		return 0
	}
	git clone -q "$ORIGIN_DIR" "$WORK_DIR" || {
		print_result "case 6: branch=feature, no default ref, no PR → branch_orphan" 1 "clone failed"
		return 0
	}
	git -C "$WORK_DIR" config user.email "test@example.com"
	git -C "$WORK_DIR" config user.name "Test"
	git -C "$WORK_DIR" remote set-head origin --delete >/dev/null 2>&1 || true
	(
		cd "$WORK_DIR" || exit 1
		git checkout -q -b feature/t9999-no-default-ref
		printf '%s\n' "feature change" > feature.txt
		git add feature.txt
		git commit -q -m "feature commit"
		git push -q origin feature/t9999-no-default-ref
	) || {
		print_result "case 6: branch=feature, no default ref, no PR → branch_orphan" 1 "feature branch setup failed"
		return 0
	}
	export STUB_PR_COUNT=0
	local got
	got=$(_worker_produced_output "issue-1006" "$WORK_DIR")
	if [[ "$got" == "branch_orphan" ]]; then
		print_result "case 6: branch=feature, no default ref, no PR → branch_orphan" 0
	else
		print_result "case 6: branch=feature, no default ref, no PR → branch_orphan" 1 "got: $got"
	fi
	return 0
}

test_external_terminal_complete_uses_trailing_issue_digits() {
	make_repo_pair "case7" || {
		print_result "case 7: external terminal complete uses trailing issue digits" 1 "fixture setup failed"
		return 0
	}
	(
		cd "$WORK_DIR" || exit 1
		git checkout -q -b feature/t24153-suffix
	) || {
		print_result "case 7: external terminal complete uses trailing issue digits" 1 "branch setup failed"
		return 0
	}
	export STUB_ISSUE_STATE="CLOSED"
	export STUB_PR_NUMBERS="77"
	export STUB_GH_LOG="${TEST_ROOT}/case7-gh.log"
	: >"$STUB_GH_LOG"
	local got="not_complete"
	if _worker_external_terminal_complete "issue-24153-123" "$WORK_DIR" >/dev/null 2>&1; then
		got="complete"
	fi
	local issue_view_call=""
	issue_view_call=$(grep -E '^issue view ' "$STUB_GH_LOG" || true)
	unset STUB_ISSUE_STATE STUB_PR_NUMBERS STUB_GH_LOG
	if [[ "$got" == "complete" && "$issue_view_call" == *"issue view 123 "* ]]; then
		print_result "case 7: external terminal complete uses trailing issue digits" 0
	else
		print_result "case 7: external terminal complete uses trailing issue digits" 1 "got: $got; issue call: ${issue_view_call:-<none>}"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

test_main_no_commits_no_pr_returns_noop
test_main_with_local_commits_no_pr_returns_noop_t2899
test_feature_branch_pushed_no_pr_returns_branch_orphan
test_feature_branch_with_pr_returns_pr_exists
test_failure_recovery_ignores_default_branch_pr_match
test_feature_branch_without_default_ref_returns_branch_orphan
test_external_terminal_complete_uses_trailing_issue_digits

printf '\nRan %d test(s), %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

# Restore original HOME for any post-trap cleanup.
export HOME="$ORIGINAL_HOME"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
