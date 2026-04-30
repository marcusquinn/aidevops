#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dirty-pr-sweep-interactive-stale.sh — Regression tests for the
# stale-stamp-aware origin:interactive takeover path (GH#21891).
#
# Tests the _dps_interactive_stamp_is_stale helper and the full
# _dirty_pr_classify flow for stale origin:interactive DIRTY PRs.
#
# Cases:
#   1. origin:interactive, stale (no commits/comments in 4h), TODO-only conflict
#      → classify returns "rebase|..." action (cross-runner takeover allowed).
#   2. origin:interactive, recent commit within staleness window
#      → still notify-only (not stale, do not takeover).
#   3. origin:interactive, recent author comment within staleness window
#      → still notify-only (author is still present).
#   4. origin:interactive, gh API error on commit fetch
#      → fail-safe to notify-only (no surprise takeover on network blip).
#   5. origin:worker PR (existing path) — rebase_author_ok unchanged.
#   6. author == self_login (existing path) — rebase_author_ok unchanged.
#
# The _dps_interactive_stamp_is_stale helper is tested through stubs of `gh`
# that simulate the API responses for each scenario. No real network calls
# are made. No real PRs are touched.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME + fake repos.json so sourcing is side-effect free.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor" \
	"${HOME}/.config/aidevops"
printf '%s' '{"initialized_repos":[]}' >"${HOME}/.config/aidevops/repos.json"

export DIRTY_PR_SWEEP_LAST_RUN="${HOME}/.aidevops/logs/dirty-pr-sweep-last-run"
export DIRTY_PR_SWEEP_STATE_FILE="${HOME}/.aidevops/.agent-workspace/supervisor/dirty-pr-sweep-state.json"

# Source the module under test.
# shellcheck source=../pulse-dirty-pr-sweep.sh
source "${TEST_SCRIPTS_DIR}/pulse-dirty-pr-sweep.sh" || {
	printf 'FAIL: sourcing pulse-dirty-pr-sweep.sh failed\n' >&2
	exit 1
}

# Stub directory for gh CLI.
STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$STUB_DIR"

# Helper: make a synthetic PR JSON object.
# Args: $1=number $2=mss $3=createdAt $4=updatedAt $5=author $6=headRef
#       $7=labels_json $8=body
mkpr() {
	local n="$1" mss="$2" created="$3" updated="$4" author="$5" head="$6" labels_json="$7"
	local body="${8:-}"
	local labels_array
	labels_array=$(printf '%s' "$labels_json" | jq '[.[] | {name: .}]')
	jq -n \
		--argjson n "$n" \
		--arg mss "$mss" \
		--arg created "$created" \
		--arg updated "$updated" \
		--arg author "$author" \
		--arg head "$head" \
		--argjson labels "$labels_array" \
		--arg body "$body" \
		'{number:$n, mergeStateStatus:$mss, createdAt:$created, updatedAt:$updated,
			author:{login:$author}, labels:$labels, headRefName:$head, baseRefName:"main", body:$body}'
	return 0
}

# Helper: ISO timestamp for "N seconds ago".
iso_n_seconds_ago() {
	local n="$1"
	local target
	target=$(($(date +%s) - n))
	if date -u -d "@$target" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
		date -u -d "@$target" '+%Y-%m-%dT%H:%M:%SZ'
	else
		date -u -r "$target" '+%Y-%m-%dT%H:%M:%SZ'
	fi
	return 0
}

# Build a minimal git repo with a TODO-only conflict between origin/main and
# a feature branch — used for cases that need rebase eligibility.
REPO_ROOT="${TEST_ROOT}/repo"
setup_repo_with_todo_conflict() {
	rm -rf "$REPO_ROOT"
	mkdir -p "$REPO_ROOT"
	(
		cd "$REPO_ROOT" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "tester"
		git config commit.gpgsign false
		printf '# base\n' >TODO.md
		git add -A && git commit -qm "base"
		printf '# base\nmain-side\n' >TODO.md
		git add TODO.md && git commit -qm "main: add main-side"
		git update-ref refs/remotes/origin/main main
		git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
		git checkout -qb feature/interactive-stale HEAD~1
		printf '# base\nfeature-side\n' >TODO.md
		git add TODO.md && git commit -qm "feature: add feature-side"
	)
	return 0
}

# Helper: install a gh stub that controls API responses for staleness tests.
# Args:
#   $1 - last_commit_iso  (ISO string for the last commit on the head ref)
#   $2 - last_comment_iso (ISO string for last author comment, or "" to omit)
#   $3 - simulate_api_error (1=return non-zero from commits endpoint)
install_gh_stub() {
	local last_commit_iso="$1"
	local last_comment_iso="$2"
	local simulate_api_error="${3:-0}"

	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Minimal gh stub for staleness tests.
case "\$*" in
	*"commits/"*--jq*)
		[[ "${simulate_api_error}" == "1" ]] && exit 1
		printf '%s\n' "${last_commit_iso}"
		exit 0
		;;
	*"issues/"*"/comments"*--jq*)
		if [[ -n "${last_comment_iso}" ]]; then
			printf '%s\n' "${last_comment_iso}"
		fi
		exit 0
		;;
	"pr view"*"--json comments"*)
		printf '{"comments":[]}\n'
		exit 0
		;;
	"issue view"*)
		printf '{"state":"OPEN","labels":[]}\n'
		exit 0
		;;
	"api"*"user"*)
		printf '{"login":"marcusquinn"}\n'
		exit 0
		;;
	*)
		exit 0
		;;
esac
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

PATH_ORIG="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Use a small staleness window so tests are deterministic with synthetic times.
# 3600s = 1h. Timestamps "5h ago" are stale; "30min ago" are live.
export DIRTY_PR_INTERACTIVE_STALE_AGE=3600

# =============================================================================
# Case 1: origin:interactive, stale (commit + comment both 5h old), TODO-only
#         conflict → classify should return "rebase|..." (takeover allowed).
# =============================================================================

setup_repo_with_todo_conflict
install_gh_stub "$(iso_n_seconds_ago $((5 * 3600)))" "$(iso_n_seconds_ago $((5 * 3600)))"

PR_STALE_INTERACTIVE=$(mkpr 700 "DIRTY" \
	"$(iso_n_seconds_ago $((8 * 3600)))" \
	"$(iso_n_seconds_ago $((5 * 3600)))" \
	"other-maintainer" \
	"feature/interactive-stale" \
	'["origin:interactive"]' \
	"Implements the plan. Resolves #12345.")

decision=$(_dirty_pr_classify "$PR_STALE_INTERACTIVE" "test/repo" "$REPO_ROOT" "self-runner")
case "$decision" in
	rebase\|*) print_result "case1: stale origin:interactive + TODO-only conflict → rebase (takeover)" 0 ;;
	notify\|*) print_result "case1: stale origin:interactive + TODO-only conflict → rebase (takeover)" 1 "got: $decision (expected rebase, got notify — takeover not triggered)" ;;
	*) print_result "case1: stale origin:interactive + TODO-only conflict → rebase (takeover)" 1 "got: $decision" ;;
esac

# =============================================================================
# Case 2: origin:interactive, recent commit (30min old) → notify-only.
#         The interactive session is still active; do not takeover.
# =============================================================================

install_gh_stub "$(iso_n_seconds_ago 1800)" ""  # recent commit, no author comments

PR_RECENT_COMMIT=$(mkpr 710 "DIRTY" \
	"$(iso_n_seconds_ago $((8 * 3600)))" \
	"$(iso_n_seconds_ago 1800)" \
	"other-maintainer" \
	"feature/interactive-stale" \
	'["origin:interactive"]' \
	"Work in progress. Resolves #12345.")

decision=$(_dirty_pr_classify "$PR_RECENT_COMMIT" "test/repo" "$REPO_ROOT" "self-runner")
case "$decision" in
	notify\|*) print_result "case2: origin:interactive with recent commit (30min) → notify-only" 0 ;;
	rebase\|*) print_result "case2: origin:interactive with recent commit (30min) → notify-only" 1 "got: $decision (must NOT takeover when commit is recent)" ;;
	*) print_result "case2: origin:interactive with recent commit (30min) → notify-only" 1 "got: $decision" ;;
esac

# =============================================================================
# Case 3: origin:interactive, recent author comment (30min old) → notify-only.
#         Commit is stale but author just posted a comment — session is live.
# =============================================================================

install_gh_stub "$(iso_n_seconds_ago $((5 * 3600)))" "$(iso_n_seconds_ago 1800)"  # stale commit, recent comment

PR_RECENT_COMMENT=$(mkpr 720 "DIRTY" \
	"$(iso_n_seconds_ago $((8 * 3600)))" \
	"$(iso_n_seconds_ago $((5 * 3600)))" \
	"other-maintainer" \
	"feature/interactive-stale" \
	'["origin:interactive"]' \
	"Nearly done. Resolves #12345.")

decision=$(_dirty_pr_classify "$PR_RECENT_COMMENT" "test/repo" "$REPO_ROOT" "self-runner")
case "$decision" in
	notify\|*) print_result "case3: origin:interactive with recent author comment → notify-only" 0 ;;
	rebase\|*) print_result "case3: origin:interactive with recent author comment → notify-only" 1 "got: $decision (must NOT takeover when author recently commented)" ;;
	*) print_result "case3: origin:interactive with recent author comment → notify-only" 1 "got: $decision" ;;
esac

# =============================================================================
# Case 4: origin:interactive, gh API error on commit fetch → fail-safe notify.
#         On network error the helper must return 1 (live) — no surprise takeover.
# =============================================================================

install_gh_stub "" "" "1"  # simulate API error

PR_API_ERROR=$(mkpr 730 "DIRTY" \
	"$(iso_n_seconds_ago $((8 * 3600)))" \
	"$(iso_n_seconds_ago $((5 * 3600)))" \
	"other-maintainer" \
	"feature/interactive-stale" \
	'["origin:interactive"]' \
	"Pending. Resolves #12345.")

decision=$(_dirty_pr_classify "$PR_API_ERROR" "test/repo" "$REPO_ROOT" "self-runner")
case "$decision" in
	notify\|*) print_result "case4: API error → fail-safe notify-only (no surprise takeover)" 0 ;;
	rebase\|*) print_result "case4: API error → fail-safe notify-only (no surprise takeover)" 1 "got: $decision (must NOT rebase when API is unavailable)" ;;
	*) print_result "case4: API error → fail-safe notify-only (no surprise takeover)" 1 "got: $decision" ;;
esac

# =============================================================================
# Case 5: origin:worker PR — existing rebase_author_ok path unchanged.
#         A worker PR with TODO-only conflict should still classify as rebase.
# =============================================================================

setup_repo_with_todo_conflict
install_gh_stub "" ""  # worker path never calls staleness helper

PR_WORKER=$(mkpr 740 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"some-external-contributor" \
	"feature/interactive-stale" \
	'["origin:worker"]' \
	"Worker PR. Resolves #99999.")

decision=$(_dirty_pr_classify "$PR_WORKER" "test/repo" "$REPO_ROOT" "self-runner")
case "$decision" in
	rebase\|*) print_result "case5: origin:worker PR → existing rebase path unchanged" 0 ;;
	notify\|*) print_result "case5: origin:worker PR → existing rebase path unchanged" 1 "got: $decision (worker rebase path must still work)" ;;
	*) print_result "case5: origin:worker PR → existing rebase path unchanged" 1 "got: $decision" ;;
esac

# =============================================================================
# Case 6: author == self_login — existing rebase_author_ok path unchanged.
#         Maintainer's own PR with TODO-only conflict should still rebase.
# =============================================================================

setup_repo_with_todo_conflict
install_gh_stub "" ""  # self-authored path never calls staleness helper

PR_SELF=$(mkpr 750 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"self-runner" \
	"feature/interactive-stale" \
	'["origin:interactive"]' \
	"My own PR. Resolves #77777.")

decision=$(_dirty_pr_classify "$PR_SELF" "test/repo" "$REPO_ROOT" "self-runner")
case "$decision" in
	rebase\|*) print_result "case6: author == self_login → existing self-author rebase path unchanged" 0 ;;
	notify\|*) print_result "case6: author == self_login → existing self-author rebase path unchanged" 1 "got: $decision (self-authored rebase path must still work)" ;;
	*) print_result "case6: author == self_login → existing self-author rebase path unchanged" 1 "got: $decision" ;;
esac

# Restore PATH.
export PATH="$PATH_ORIG"

# =============================================================================
# Summary
# =============================================================================

printf '\n---\nTotal: %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
