#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-push-head.sh — GH#33381 regression guard.
#
# Uses a real local bare origin to verify that _push_branch:
#   1. pushes a new branch with an explicit absent-ref lease;
#   2. rewrites its own history (rebase) with a lease on the observed SHA;
#   3. preserves a diverged foreign remote branch untouched and publishes the
#      work under "<branch>-r2", recording it in FULL_LOOP_PUSHED_BRANCH;
#   4. refuses (pushes nothing) when the foreign branch backs an open PR that
#      was not explicitly authorized with --replace-pr;
#   5. canonical sync treats a bare common Git directory as not applicable.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$1"
	return 0
}
fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t gh33381.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
LOG="${TMP}/log"
: >"$LOG"

print_info() { printf '[INFO] %s\n' "$*" >>"$LOG"; return 0; }
print_error() { printf '[ERROR] %s\n' "$*" >>"$LOG"; return 0; }
print_warning() { printf '[WARN] %s\n' "$*" >>"$LOG"; return 0; }

OPEN_PR_NUMBER=""
gh() {
	printf 'gh %s\n' "$*" >>"$LOG"
	[[ -n "$OPEN_PR_NUMBER" ]] && printf '%s\n' "$OPEN_PR_NUMBER"
	return 0
}

for fn in _classify_remote_branch _replacement_branch_name _push_branch; do
	# shellcheck disable=SC2312
	eval "$(sed -n "/^${fn}() {/,/^}/p" "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"
done

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q --bare "${TMP}/origin.git"
git init -q -b main "${TMP}/work"
cd "${TMP}/work" || exit 1
git config user.email t@example.invalid
git config user.name t
git config core.hooksPath /dev/null
git remote add origin "${TMP}/origin.git"
git commit -q --allow-empty -m base
git push -q origin main
BR="feature/gh33381"
remote_sha() { git ls-remote --heads origin "refs/heads/$1" | awk '{print $1}'; return 0; }

# 1. New branch → absent lease.
git checkout -q -b "$BR"
git commit -q --allow-empty -m one
: >"$LOG"
if _push_branch "$BR" 0 "owner/repo" && [[ "$(remote_sha "$BR")" == "$(git rev-parse HEAD)" ]] &&
	[[ "$FULL_LOOP_PUSHED_BRANCH" == "$BR" ]]; then
	pass "absent remote: branch published under its own name"
else
	fail "absent remote: branch published under its own name" "$(cat "$LOG")"
fi

# 2. Own rewrite (amend) → explicit-SHA lease, overwrite allowed.
git commit -q --amend --allow-empty -m one-amended
: >"$LOG"
if _push_branch "$BR" 0 "owner/repo" && [[ "$(remote_sha "$BR")" == "$(git rev-parse HEAD)" ]]; then
	pass "own rewrite: reflog-proven history is replaced with a lease"
else
	fail "own rewrite: reflog-proven history is replaced with a lease" "$(cat "$LOG")"
fi

# 3. Foreign divergence (another clone pushed unrelated history) → preserved.
git clone -q "${TMP}/origin.git" "${TMP}/other"
(cd "${TMP}/other" && git config user.email o@example.invalid && git config user.name o &&
	git checkout -q -B "$BR" origin/main && git commit -q --allow-empty -m foreign &&
	git push -q -f origin "$BR") || exit 1
foreign_sha=$(remote_sha "$BR")
git commit -q --allow-empty -m two
: >"$LOG"
if _push_branch "$BR" 0 "owner/repo" &&
	[[ "$(remote_sha "$BR")" == "$foreign_sha" ]] &&
	[[ "$FULL_LOOP_PUSHED_BRANCH" == "${BR}-r2" ]] &&
	[[ "$(remote_sha "${BR}-r2")" == "$(git rev-parse HEAD)" ]] &&
	[[ "$(git branch --show-current)" == "${BR}-r2" ]]; then
	pass "foreign divergence: remote preserved, work published as ${BR}-r2"
else
	fail "foreign divergence: remote preserved, work published as ${BR}-r2" "$(cat "$LOG")"
fi

# 4. Foreign divergence backing an open PR → refuse, nothing pushed.
git checkout -q -b "${BR}-x" main
git commit -q --allow-empty -m three
git branch -q -m "${BR}-x" "$BR"
OPEN_PR_NUMBER="77"
: >"$LOG"
rc=0
_push_branch "$BR" 0 "owner/repo" || rc=$?
if [[ "$rc" -ne 0 && "$(remote_sha "$BR")" == "$foreign_sha" && -z "$(remote_sha "${BR}-r3")" ]] &&
	grep -q -- '--replace-pr' "$LOG"; then
	pass "open foreign PR: refuses without --replace-pr and pushes nothing"
else
	fail "open foreign PR: refuses without --replace-pr and pushes nothing" "rc=${rc}; $(cat "$LOG")"
fi

# 5. Bare common Git directory → explicit not-applicable state, no mirror-sync
#    instruction and no working-tree commands against the bare repository.
# shellcheck disable=SC2312
eval "$(sed -n '/^_merge_report_canonical_sync_state() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-merge-cleanup.sh")"
print_success() { printf '[OK] %s\n' "$*" >>"$LOG"; return 0; }
: >"$LOG"
bare_out=""
bare_rc=0
bare_out=$(_merge_report_canonical_sync_state "${TMP}/origin.git" 123 "") || bare_rc=$?
if [[ "$bare_rc" -ne 0 && "$bare_out" != *"CANONICAL_SYNC_NEXT"* ]] &&
	grep -q 'CANONICAL_SYNC_NOT_APPLICABLE reason=bare_common_dir' "$LOG"; then
	pass "bare common dir: reported as not applicable, no false sync failure"
else
	fail "bare common dir: reported as not applicable, no false sync failure" "rc=${bare_rc}; out=${bare_out}; $(cat "$LOG")"
fi

printf '\n%d/%d passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
