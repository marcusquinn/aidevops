#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Fixture test for GH#40476: after worktree_base_dir moves, storage hygiene
# still reports the legacy base (counts, sizes, survival classes), and the
# gitlocks preview sizes pack temporaries the age gate keeps.

set -uo pipefail

TEST_NATIVE_GIT=$(command -p -v git) || {
	printf '%s\n' 'Native Git is unavailable on the system PATH' >&2
	exit 1
}
export TEST_NATIVE_GIT
GIT="$TEST_NATIVE_GIT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/storage-cleanup-helper.sh"
ROOT=$(mktemp -d)
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
FAILURES=0

cleanup() {
	rm -rf "$ROOT"
	return 0
}
trap cleanup EXIT

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CEILING_DIRECTORIES \
	AIDEVOPS_WORKTREE_BASE_DIR AIDEVOPS_WORKTREES_DIR AIDEVOPS_LEGACY_WORKTREE_BASES
export HOME="${ROOT}/home"
export XDG_DATA_HOME="${HOME}/.local/share"
export AIDEVOPS_REPOS_JSON="${HOME}/.config/aidevops/repos.json"
export AIDEVOPS_LOG_DIR="${HOME}/.aidevops/logs"
export AIDEVOPS_REAL_GIT_BIN="$GIT"
# Docker sizing is out of scope; a failing stub keeps the report offline.
mkdir -p "${ROOT}/bin"
printf '#!/bin/sh\nexit 1\n' >"${ROOT}/bin/docker"
chmod +x "${ROOT}/bin/docker"
export PATH="${ROOT}/bin:${PATH}"

pass() {
	printf 'PASS %s\n' "$1"
	return 0
}
fail() {
	printf 'FAIL %s\n' "$1"
	FAILURES=$((FAILURES + 1))
	return 0
}

init_repo() {
	local repo="$1"
	mkdir -p "$repo"
	"$GIT" -C "$repo" init -q -b main
	"$GIT" -C "$repo" config user.name Test
	"$GIT" -C "$repo" config user.email test@example.invalid
	"$GIT" -C "$repo" config commit.gpgsign false
	"$GIT" -C "$repo" config gc.auto 0
	printf 'seed\n' >"${repo}/README.md"
	"$GIT" -C "$repo" add README.md
	"$GIT" -C "$repo" commit -q -m seed
	return 0
}

REPO="${HOME}/Git/repo"
OTHER="${ROOT}/other"
NEW_BASE="${ROOT}/new-base"
LEGACY="${HOME}/Git/_worktrees"
EXTRA="${ROOT}/extra-base"
init_repo "$REPO"
init_repo "$OTHER"
mkdir -p "$NEW_BASE" "$LEGACY" "$EXTRA/scratch" "${HOME}/.config/aidevops"
ln -s "$EXTRA" "${ROOT}/extra-link"
cat >"$AIDEVOPS_REPOS_JSON" <<JSON
{"worktree_base_dir":"${NEW_BASE}","initialized_repos":[{"path":"${REPO}","slug":"example/repo","local_only":false}]}
JSON

"$GIT" -C "$REPO" worktree add -q "${NEW_BASE}/repo-feature-new" -b feature/new
# Legacy base: one managed worktree inside the repo parent (relocate scope),
# one for an unmanaged repo, one stale pointer and one plain directory.
"$GIT" -C "$REPO" worktree add -q "${LEGACY}/repo-feature-old" -b feature/old
"$GIT" -C "$OTHER" worktree add -q "${LEGACY}/other-feature-x" -b feature/x
mkdir -p "${LEGACY}/repo-gone"
printf 'gitdir: %s/missing/.git/worktrees/gone\n' "$ROOT" >"${LEGACY}/repo-gone/.git"
mkdir -p "${LEGACY}/notes"
dd if=/dev/zero of="${LEGACY}/notes/blob" bs=1024 count=256 2>/dev/null

export AIDEVOPS_LEGACY_WORKTREE_BASES="${EXTRA}:${ROOT}/extra-link:${NEW_BASE}"

report=$(bash "$HELPER" report 2>&1) || fail "report exited non-zero: $report"
if [[ "$report" == *"(6 worktrees)"* &&
	"$report" == *"configured ${NEW_BASE}: 1 worktrees ("* &&
	"$report" == *"legacy ${LEGACY}: 4 worktrees ("* &&
	"$report" == *"legacy ${EXTRA}: 1 worktrees ("* ]]; then
	pass "report lists the configured and every legacy base with counts and sizes"
else
	fail "report base lines incomplete: $report"
fi
if [[ "$report" != *"extra-link"* && "$(grep -c "^ .*${NEW_BASE}:" <<<"$report")" == 1 ]]; then
	pass "report skips symlinked and duplicate legacy bases"
else
	fail "report listed a symlinked or duplicate base: $report"
fi

preview=$(bash "$HELPER" worktrees 2>&1) || fail "worktrees preview exited non-zero: $preview"
if [[ "$preview" == *"Linked worktrees: 1 under ${NEW_BASE}"* &&
	"$preview" == *"Legacy base ${LEGACY}: 4 entries; managed 1 (relocate scope 1), unmanaged 1, stale 1, other 1"* &&
	"$preview" == *"Legacy base ${EXTRA}: 1 entries; managed 0 (relocate scope 0), unmanaged 0, stale 0, other 1"* ]]; then
	pass "worktrees preview classifies why each legacy entry survives"
else
	fail "worktrees preview classification incomplete: $preview"
fi

unset AIDEVOPS_LEGACY_WORKTREE_BASES
dd if=/dev/zero of="${REPO}/.git/objects/pack/tmp_pack_young" bs=1024 count=2048 2>/dev/null
locks=$(bash "$HELPER" gitlocks 2>&1) || fail "gitlocks preview exited non-zero: $locks"
if [[ "$locks" == *"repo: stale_locks=0 tmp_packs=0 tmp_pack_bytes=2.0M (young 2.0M kept until 2+ days old)"* &&
	"$locks" == *"Pack temporaries: 2.0M found, 2.0M still inside the 2-day age gate (kept)."* &&
	-f "${REPO}/.git/objects/pack/tmp_pack_young" ]]; then
	pass "gitlocks preview sizes a young pack temporary and keeps it"
else
	fail "gitlocks preview hid the young pack temporary: $locks"
fi

if [[ "$FAILURES" -eq 0 ]]; then
	printf 'All storage legacy-base checks passed\n'
	exit 0
fi
printf '%s storage legacy-base check(s) failed\n' "$FAILURES"
exit 1
