#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#27357 review follow-up findings.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d -t transactional-launch-metadata.XXXXXX)" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	printf 'FAIL %s\n' "$name" >&2
	return 1
}

# shellcheck disable=SC1090
(
	SCRIPT_DIR="$SCRIPTS_DIR"
	source "${SCRIPTS_DIR}/dispatch-dedup-stale.sh"
	gh() {
		printf '%s\n' '{"state":"OPEN","labels":[{"name":"status:available"}],"assignees":null}'
		return 0
	}
	_stale_recovery_verify_transition "27357" "owner/repo" "available" "runner-a"
) || fail "stale recovery accepts null assignees after ownership removal"
pass "stale recovery accepts null assignees after ownership removal"

# shellcheck disable=SC1090
(
	SCRIPT_DIR="$SCRIPTS_DIR"
	source "${SCRIPTS_DIR}/pulse-cleanup.sh"
	gh() {
		printf '%s\n' '{"state":"OPEN","labels":[{"name":"status:available"}],"assignees":null}'
		return 0
	}
	_verify_launch_recovery_state "27357" "owner/repo" "runner-a" "available"
) || fail "launch recovery accepts null assignees after ownership removal"
pass "launch recovery accepts null assignees after ownership removal"

# shellcheck disable=SC1090
(
	SCRIPT_DIR="$SCRIPTS_DIR"
	LOGFILE="${TEST_ROOT}/pulse.log"
	source "${SCRIPTS_DIR}/shared-constants.sh"
	source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
	source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"
	gh() {
		local resource="$1"
		local action="${2:-}"
		if [[ "$resource" == "api" ]]; then
			printf '%s\n' 'claim-27357'
			return 0
		fi
		if [[ "$resource" == "issue" && "$action" == "view" ]]; then
			printf '%s\n' '{"state":"OPEN","labels":null,"assignees":null,"locked":false}'
			return 0
		fi
		return 1
	}
	_rollback_prelaunch_ownership "27357" "owner/repo" "runner-a" "claim-27357"
) || fail "pre-launch rollback treats null ownership metadata as unowned"
pass "pre-launch rollback treats null ownership metadata as unowned"

REMOTE="${TEST_ROOT}/remote.git"
CANONICAL="${TEST_ROOT}/canonical"
UPDATER="${TEST_ROOT}/updater"
WORKTREES="${TEST_ROOT}/worktrees"
git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$CANONICAL"
git -C "$CANONICAL" switch -q -c main
git -C "$CANONICAL" config user.name Test
git -C "$CANONICAL" config user.email test@example.invalid
git -C "$CANONICAL" commit -q --allow-empty -m seed
git -C "$CANONICAL" push -q -u origin main
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main

git clone -q "$REMOTE" "$UPDATER"
git -C "$UPDATER" config user.name Test
git -C "$UPDATER" config user.email test@example.invalid
git -C "$UPDATER" switch -q -c feature/remote-only
printf 'remote branch\n' >"${UPDATER}/remote-only.txt"
git -C "$UPDATER" add remote-only.txt
git -C "$UPDATER" commit -q -m remote-only
git -C "$UPDATER" push -q -u origin feature/remote-only
REMOTE_ONLY_SHA="$(git -C "$UPDATER" rev-parse HEAD)"

if git -C "$CANONICAL" show-ref --verify --quiet refs/remotes/origin/feature/remote-only; then
	fail "fixture unexpectedly has the remote-only tracking ref"
fi

# shellcheck disable=SC1090
(
	export AIDEVOPS_WORKTREE_BASE_DIR="$WORKTREES"
	SCRIPT_DIR="$SCRIPTS_DIR"
	source "${SCRIPTS_DIR}/worktree-helper-add.sh"
	cd "$CANONICAL" || exit 1
	_worktree_refresh_origin_branch "feature/remote-only"
) || fail "HEAD bootstrap fetches a branch without a local tracking ref"

[[ "$(git -C "$CANONICAL" rev-parse refs/remotes/origin/feature/remote-only)" == "$REMOTE_ONLY_SHA" ]] ||
	fail "remote-only tracking ref was not refreshed"
if compgen -G "${WORKTREES}/.canonical-fetch-*" >/dev/null; then
	fail "temporary HEAD bootstrap worktree was not removed"
fi
pass "HEAD bootstrap fetches a branch without a local tracking ref"

exit 0
