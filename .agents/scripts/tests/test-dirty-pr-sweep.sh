#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dirty-pr-sweep.sh — Regression tests for pulse-dirty-pr-sweep.sh
# (t2350 / GH#19948).
#
# Covers the three classification paths and the cross-cutting safety gates:
#
#   1. Rebase path   — young PR (< 48h), maintainer-owned, only TODO.md
#                      conflicts → classify returns "rebase|todo-only-conflict".
#   2. Close path    — old PR (> 7d), idle (> 3d), no opt-out label
#                      → classify returns "close|stale-and-idle".
#   3. Escalate path — young PR with non-TODO conflicts → classify returns
#                      "escalate|..." (never rebase or close).
#   4. Opt-out       — `do-not-close` label forces escalate, never close.
#   5. Opt-out       — `parent-task` label forces escalate, never close.
#   6. Opt-out       — `origin:interactive` label forces escalate, never close.
#   7. Idempotency   — a recorded action within the cooldown window is
#                      honoured (classify still returns a decision, but the
#                      action helper short-circuits on _dps_recently_actioned).
#   8. Dry-run       — DRY_RUN=1 never calls `gh pr close` or `git rebase`.
#   9. Interval gate — sweep returns early when DIRTY_PR_SWEEP_LAST_RUN is
#                      within DIRTY_PR_SWEEP_INTERVAL.
#
# The sweep classifier is pure given its JSON input — no network calls. For
# action tests we stub `gh` so no real PRs are touched.

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
# Minimal repos.json (empty initialized_repos array)
printf '%s' '{"initialized_repos":[]}' >"${HOME}/.config/aidevops/repos.json"

# Point state + interval files at the sandbox so classification tests never
# touch real state.
export DIRTY_PR_SWEEP_LAST_RUN="${HOME}/.aidevops/logs/dirty-pr-sweep-last-run"
export DIRTY_PR_SWEEP_STATE_FILE="${HOME}/.aidevops/.agent-workspace/supervisor/dirty-pr-sweep-state.json"

# Source the module. shellcheck disable=SC1091
# shellcheck source=../pulse-dirty-pr-sweep.sh
source "${TEST_SCRIPTS_DIR}/pulse-dirty-pr-sweep.sh" || {
	echo "FAIL: sourcing pulse-dirty-pr-sweep.sh failed" >&2
	exit 1
}

# Helper: make a synthetic PR JSON object matching the fields
# _dirty_pr_classify reads from `gh pr list`.
# Args: $1=number $2=mss $3=createdAt $4=updatedAt $5=author $6=headRef
#       $7=labels_json (e.g. '["origin:worker"]' or '[]')
mkpr() {
	local n="$1" mss="$2" created="$3" updated="$4" author="$5" head="$6" labels_json="$7"
	local tmpfile
	tmpfile=$(mktemp)
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
		'{number:$n, mergeStateStatus:$mss, createdAt:$created, updatedAt:$updated,
			author:{login:$author}, labels:$labels, headRefName:$head, baseRefName:"main"}' \
		>"$tmpfile"
	cat "$tmpfile"
	rm -f "$tmpfile"
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
		# macOS BSD date
		date -u -r "$target" '+%Y-%m-%dT%H:%M:%SZ'
	fi
	return 0
}

# =============================================================================
# Test 1: rebase path — young PR, maintainer-owned, only TODO.md conflicts
# =============================================================================

# Build a minimal ephemeral git repo where ONLY TODO.md conflicts between
# a feature branch and origin/main.
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
		printf '# base\n' >unrelated.md
		git add -A && git commit -qm "base"
		# Advance "main" with a new TODO.md line.
		printf '# base\nmain-side\n' >TODO.md
		git add TODO.md && git commit -qm "main: add main-side"
		git update-ref refs/remotes/origin/main main
		# Feature branch diverges from the base commit.
		git checkout -qb feature/todo-conflict HEAD~1
		printf '# base\nfeature-side\n' >TODO.md
		git add TODO.md && git commit -qm "feature: add feature-side"
	)
	return 0
}

setup_repo_with_todo_conflict
PR_YOUNG_WORKER=$(mkpr 100 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"marcusquinn" \
	"feature/todo-conflict" \
	'["origin:worker"]')

decision=$(_dirty_pr_classify "$PR_YOUNG_WORKER" "test/repo" "$REPO_ROOT" "marcusquinn")
case "$decision" in
	rebase\|*) print_result "rebase path: young + worker-origin + TODO-only → rebase" 0 ;;
	*) print_result "rebase path: young + worker-origin + TODO-only → rebase" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 2: close path — stale + idle + no opt-out
# =============================================================================

PR_STALE=$(mkpr 200 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"some-external-user" \
	"feature/old" \
	'[]')

decision=$(_dirty_pr_classify "$PR_STALE" "test/repo" "" "marcusquinn")
case "$decision" in
	close\|*) print_result "close path: >7d old + >3d idle → close" 0 ;;
	*) print_result "close path: >7d old + >3d idle → close" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 3: escalate path — non-TODO conflicts
# =============================================================================

# Build a repo where a non-TODO file conflicts
setup_repo_with_nontodo_conflict() {
	rm -rf "$REPO_ROOT"
	mkdir -p "$REPO_ROOT"
	(
		cd "$REPO_ROOT" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "tester"
		git config commit.gpgsign false
		printf 'base-code\n' >src.sh
		git add -A && git commit -qm "base"
		printf 'main-side-code\n' >src.sh
		git add src.sh && git commit -qm "main: modify"
		git update-ref refs/remotes/origin/main main
		git checkout -qb feature/code-conflict HEAD~1
		printf 'feature-side-code\n' >src.sh
		git add src.sh && git commit -qm "feature: modify"
	)
	return 0
}

setup_repo_with_nontodo_conflict
PR_CODE_CONFLICT=$(mkpr 300 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"marcusquinn" \
	"feature/code-conflict" \
	'["origin:worker"]')

decision=$(_dirty_pr_classify "$PR_CODE_CONFLICT" "test/repo" "$REPO_ROOT" "marcusquinn")
case "$decision" in
	escalate\|*) print_result "escalate path: non-TODO conflicts → escalate (no rebase)" 0 ;;
	*) print_result "escalate path: non-TODO conflicts → escalate (no rebase)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 4: do-not-close opt-out
# =============================================================================

PR_OPTOUT=$(mkpr 400 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/foo" \
	'["do-not-close"]')

decision=$(_dirty_pr_classify "$PR_OPTOUT" "test/repo" "" "marcusquinn")
case "$decision" in
	escalate\|do-not-close-label) print_result "opt-out: do-not-close label → escalate" 0 ;;
	close\|*) print_result "opt-out: do-not-close label → escalate" 1 "got: $decision (should NOT be close)" ;;
	*) print_result "opt-out: do-not-close label → escalate" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 5: parent-task opt-out
# =============================================================================

PR_PARENT=$(mkpr 500 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"marcusquinn" \
	"feature/bar" \
	'["origin:worker", "parent-task"]')

decision=$(_dirty_pr_classify "$PR_PARENT" "test/repo" "" "marcusquinn")
case "$decision" in
	escalate\|parent-task-label) print_result "opt-out: parent-task label → escalate (no rebase)" 0 ;;
	rebase\|*) print_result "opt-out: parent-task label → escalate (no rebase)" 1 "got: $decision (must NOT rebase)" ;;
	close\|*) print_result "opt-out: parent-task label → escalate (no rebase)" 1 "got: $decision (must NOT close)" ;;
	*) print_result "opt-out: parent-task label → escalate (no rebase)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6: origin:interactive never auto-closes
# =============================================================================

PR_INTERACTIVE=$(mkpr 600 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/baz" \
	'["origin:interactive"]')

decision=$(_dirty_pr_classify "$PR_INTERACTIVE" "test/repo" "" "marcusquinn")
case "$decision" in
	escalate\|*) print_result "opt-out: origin:interactive → escalate (never close)" 0 ;;
	close\|*) print_result "opt-out: origin:interactive → escalate (never close)" 1 "got: $decision (must NOT close)" ;;
	*) print_result "opt-out: origin:interactive → escalate (never close)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 7: idempotency — cooldown is honoured
# =============================================================================

# Record a fake action for PR #100 in test/repo and verify _dps_recently_actioned returns true.
_dps_state_record_action "test/repo#100" "rebase"
if _dps_recently_actioned "test/repo#100"; then
	print_result "idempotency: cooldown blocks re-action" 0
else
	print_result "idempotency: cooldown blocks re-action" 1 "_dps_recently_actioned returned false"
fi
if _dps_recently_actioned "test/repo#9999-unknown"; then
	print_result "idempotency: unknown key is not blocked" 1 "_dps_recently_actioned returned true for unknown key"
else
	print_result "idempotency: unknown key is not blocked" 0
fi

# Force cooldown expiry by rewriting last_action_epoch to a distant past.
ancient_state=$(jq --arg k "test/repo#100" \
	'.[$k].last_action_epoch = 1' \
	"$DIRTY_PR_SWEEP_STATE_FILE")
printf '%s' "$ancient_state" >"$DIRTY_PR_SWEEP_STATE_FILE"
if _dps_recently_actioned "test/repo#100"; then
	print_result "idempotency: stale cooldown expires" 1 "_dps_recently_actioned returned true on ancient timestamp"
else
	print_result "idempotency: stale cooldown expires" 0
fi

# =============================================================================
# Test 8: dry-run — close action never calls gh pr close
# =============================================================================

# Stub gh to record calls.
STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$STUB_DIR"
GH_CALLS_LOG="${TEST_ROOT}/gh-calls.log"
: >"$GH_CALLS_LOG"
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$GH_CALLS_LOG"
# Handle common read-only reads with empty defaults
case "\$1" in
	pr)
		case "\$2" in
			view) printf '{"comments":[]}' ;;
			close) : ;;  # noop in stub
			comment) : ;;
		esac
		;;
	issue)
		case "\$2" in
			view) printf '{"state":"OPEN","labels":[]}' ;;
		esac
		;;
	api)
		case "\$2" in
			user) printf '{"login":"marcusquinn"}' ;;
		esac
		;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/gh"

# Prepend stub to PATH
PATH_ORIG="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Clear action state so the stub call isn't cooldown-skipped.
printf '%s' '{}' >"$DIRTY_PR_SWEEP_STATE_FILE"

# Dry-run close on PR #200 (stale) — should NOT call `gh pr close`.
_DIRTY_PR_SWEEP_DRY_RUN=1
_dirty_pr_action_close 200 "test/repo" >/dev/null 2>&1
if grep -q 'gh pr close 200' "$GH_CALLS_LOG"; then
	print_result "dry-run: close does NOT execute gh pr close" 1 "gh pr close was called"
else
	print_result "dry-run: close does NOT execute gh pr close" 0
fi
_DIRTY_PR_SWEEP_DRY_RUN=0

# Restore PATH.
export PATH="$PATH_ORIG"

# =============================================================================
# Test 9: interval gate — sweep early-returns when interval not elapsed
# =============================================================================

# Reset the state file so no repos are iterated (empty repos.json).
printf '%s' '{}' >"$DIRTY_PR_SWEEP_STATE_FILE"
# Write a "recent" timestamp to the last-run file.
date +%s >"$DIRTY_PR_SWEEP_LAST_RUN"
export DIRTY_PR_SWEEP_INTERVAL=3600  # 1h — now not elapsed
# Capture interval-gate log line to confirm the gate fired.
INTERVAL_LOG="${TEST_ROOT}/interval.log"
: >"$INTERVAL_LOG"
LOGFILE="$INTERVAL_LOG" dirty_pr_sweep_all_repos
if grep -q 'interval-gate' "$INTERVAL_LOG"; then
	print_result "interval gate: early-return when not due" 0
else
	print_result "interval gate: early-return when not due" 1 "log did not show 'interval-gate'"
fi

# =============================================================================
# Summary
# =============================================================================

printf '\n---\nTotal: %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
