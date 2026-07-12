#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for diagnostic-only canonical recovery.

set -euo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
SYSTEM_GIT="$(command -p -v git)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export PULSE_CANONICAL_RECOVERY_ADVISORY_DIR="$TEST_ROOT/advisories"
export PULSE_CANONICAL_RECOVERY_STATE="$TEST_ROOT/state/recovery.json"
mkdir -p "$HOME" "$PULSE_CANONICAL_RECOVERY_ADVISORY_DIR" "$(dirname "$PULSE_CANONICAL_RECOVERY_STATE")"

passed=0
failed=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	passed=$((passed + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf 'FAIL %s: %s\n' "$name" "$detail" >&2
	failed=$((failed + 1))
	return 0
}

new_repo() {
	local repo="$1"
	"$SYSTEM_GIT" init -q -b main "$repo" 2>/dev/null || {
		"$SYSTEM_GIT" init -q "$repo"
		"$SYSTEM_GIT" -C "$repo" checkout -q -b main
	}
	"$SYSTEM_GIT" -C "$repo" config user.name Test
	"$SYSTEM_GIT" -C "$repo" config user.email test@example.com
	printf 'base\n' >"$repo/tracked.txt"
	"$SYSTEM_GIT" -C "$repo" add tracked.txt
	"$SYSTEM_GIT" -C "$repo" commit -q -m base
	return 0
}

snapshot_repo() {
	local repo="$1"
	printf 'HEAD %s\n' "$("$SYSTEM_GIT" -C "$repo" rev-parse HEAD)"
	printf 'INDEX '
	cksum <"$repo/.git/index"
	printf 'STATUS\n'
	"$SYSTEM_GIT" -C "$repo" status --porcelain=v1 --untracked-files=all
	printf 'STASH %s\n' "$("$SYSTEM_GIT" -C "$repo" rev-parse -q --verify refs/stash 2>/dev/null || true)"
	local path=""
	while IFS= read -r path; do
		printf 'FILE %s ' "$path"
		cksum <"$repo/$path"
	done < <("$SYSTEM_GIT" -C "$repo" ls-files --cached --others --exclude-standard | LC_ALL=C sort)
	return 0
}

advisory_for() {
	local repo="$1"
	local raw="" name=""
	raw=$(basename "$repo")
	name=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')
	printf '%s/canonical-recovery-%s.advisory\n' "$PULSE_CANONICAL_RECOVERY_ADVISORY_DIR" "$name"
	return 0
}

assert_diagnostic_preserves() {
	local repo="$1"
	local expected_state="$2"
	local name="$3"
	local before="" after="" output="" rc=0 advisory=""
	before=$(snapshot_repo "$repo")
	output=$(pulse_canonical_recover "$repo" 2>&1) || rc=$?
	after=$(snapshot_repo "$repo")
	advisory=$(advisory_for "$repo")

	if [[ "$rc" -ne 1 ]]; then
		fail "$name" "expected diagnostic exit 1, got $rc"
		return 0
	fi
	if [[ "$before" != "$after" ]]; then
		fail "$name" "HEAD/index/status/stash/file bytes changed"
		return 0
	fi
	if [[ ! -f "$advisory" ]] || ! grep -Fq "Failure mode: ${expected_state}" "$advisory"; then
		fail "$name" "missing local ${expected_state} advisory"
		return 0
	fi
	if [[ "$output" != *"diagnostic-only canonical state"* ]]; then
		fail "$name" "missing diagnostic-only log"
		return 0
	fi
	pass "$name"
	return 0
}

make_unmerged_repo() {
	local repo="$1"
	new_repo "$repo"
	"$SYSTEM_GIT" -C "$repo" checkout -q -b conflict
	printf 'branch\n' >"$repo/tracked.txt"
	"$SYSTEM_GIT" -C "$repo" add tracked.txt
	"$SYSTEM_GIT" -C "$repo" commit -q -m branch
	"$SYSTEM_GIT" -C "$repo" checkout -q main
	printf 'main\n' >"$repo/tracked.txt"
	"$SYSTEM_GIT" -C "$repo" add tracked.txt
	"$SYSTEM_GIT" -C "$repo" commit -q -m main
	"$SYSTEM_GIT" -C "$repo" merge conflict >/dev/null 2>&1 || true
	return 0
}

# shellcheck source=/dev/null
source "$TEST_SCRIPTS_DIR/pulse-canonical-recovery.sh"

dirty_repo="$TEST_ROOT/dirty"
new_repo "$dirty_repo"
printf 'human edit\n' >>"$dirty_repo/tracked.txt"
printf 'human untracked\n' >"$dirty_repo/untracked.txt"
assert_diagnostic_preserves "$dirty_repo" uncommitted "dirty canonical is byte-identical and advised"

todo_repo="$TEST_ROOT/generated-todo"
new_repo "$todo_repo"
printf '%s\n' '- [ ] t123 generated fixture logged:2026-01-01 assignee:worker' >"$todo_repo/TODO.md"
"$SYSTEM_GIT" -C "$todo_repo" add TODO.md
"$SYSTEM_GIT" -C "$todo_repo" commit -q -m todo
printf '%s\n' '- [x] t123 generated fixture logged:2026-01-02 assignee:worker completed:2026-01-02' >"$todo_repo/TODO.md"
assert_diagnostic_preserves "$todo_repo" uncommitted "generated TODO metadata is preserved and advised"

unmerged_repo="$TEST_ROOT/unmerged"
make_unmerged_repo "$unmerged_repo"
assert_diagnostic_preserves "$unmerged_repo" unmerged "unmerged canonical is byte-identical and advised"

clean_repo="$TEST_ROOT/clean"
new_repo "$clean_repo"
clean_before=$(snapshot_repo "$clean_repo")
clean_rc=0
pulse_canonical_recover "$clean_repo" >/dev/null 2>&1 || clean_rc=$?
clean_after=$(snapshot_repo "$clean_repo")
if [[ "$clean_rc" -eq 0 && "$clean_before" == "$clean_after" && ! -e "$(advisory_for "$clean_repo")" ]]; then
	pass "clean canonical remains a no-op"
else
	fail "clean canonical remains a no-op" "unexpected mutation, status, or advisory"
fi

printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
[[ "$failed" -eq 0 ]] || exit 1
exit 0
