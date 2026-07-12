#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
mkdir -p "$HOME/.aidevops/advisories" "$HOME/.aidevops/.agent-workspace/supervisor"

repo="$TEST_ROOT/repo"
git init -q -b main "$repo" 2>/dev/null || {
	git init -q "$repo"
	git -C "$repo" checkout -q -b main
}
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' >"$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -q -m base
printf 'human change\n' >>"$repo/tracked.txt"
printf 'untracked\n' >"$repo/untracked.txt"

snapshot() {
	local target_repo="$1"
	printf '%s\n' "$(git -C "$target_repo" rev-parse HEAD)"
	cksum <"$target_repo/.git/index"
	cksum <"$target_repo/tracked.txt"
	cksum <"$target_repo/untracked.txt"
	git -C "$target_repo" status --porcelain=v1 --untracked-files=all
	return 0
}

before=$(snapshot "$repo")
export PULSE_CANONICAL_RECOVERY_ADVISORY_DIR="$HOME/.aidevops/advisories"
export PULSE_CANONICAL_RECOVERY_STATE="$HOME/.aidevops/.agent-workspace/supervisor/state.json"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/pulse-canonical-recovery.sh"
rc=0
pulse_canonical_recover "$repo" >/dev/null 2>&1 || rc=$?
after=$(snapshot "$repo")

if [[ "$rc" -ne 1 || "$before" != "$after" ]]; then
	printf 'FAIL canonical recovery diagnostic changed checkout state (rc=%s)\n' "$rc" >&2
	exit 1
fi
if [[ ! -f "$HOME/.aidevops/advisories/canonical-recovery-repo.advisory" ]]; then
	printf 'FAIL canonical recovery diagnostic did not write local advisory\n' >&2
	exit 1
fi

printf 'PASS canonical recovery preserves exact HEAD, index, tracked, untracked, and status bytes\n'
