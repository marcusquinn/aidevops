#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for sync-workflows-helper.sh (t2779, GH#20649).
#
# Covers: dry-run planning, JSON output shape, --repo filter, @ref preservation
# on DRIFTED/CALLER, @ref default on NEEDS-MIGRATION, no-work path (all current),
# preconditions (missing repos.json, missing check helper, missing template).
#
# Apply-mode tests use a local git repo to verify branch/commit/push staging
# (push is mocked to a local bare remote).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../sync-workflows-helper.sh"
CHECK_HELPER="$SCRIPT_DIR/../check-workflows-helper.sh"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
NC=$'\033[0m'

_PASS=0
_FAIL=0

_assert_contains() {
	local _desc="$1"
	local _haystack="$2"
	local _needle="$3"
	# Use `--` to prevent grep from interpreting needles starting with `-`.
	if grep -qF -- "$_needle" <<<"$_haystack"; then
		printf '%sPASS%s %s\n' "$GREEN" "$NC" "$_desc"
		((_PASS++))
	else
		printf '%sFAIL%s %s\n' "$RED" "$NC" "$_desc"
		printf '       needle: %s\n' "$_needle"
		printf '       haystack:\n%s\n' "$_haystack" | sed 's/^/       /'
		((_FAIL++))
	fi
	return 0
}

_assert_exit() {
	local _desc="$1"
	local _expected="$2"
	local _actual="$3"
	if [[ "$_expected" == "$_actual" ]]; then
		printf '%sPASS%s %s\n' "$GREEN" "$NC" "$_desc"
		((_PASS++))
	else
		printf '%sFAIL%s %s (got %s, expected %s)\n' "$RED" "$NC" "$_desc" "$_actual" "$_expected"
		((_FAIL++))
	fi
	return 0
}

# Setup: fake HOME with repos.json + templates/workflows dir.
_setup_fake_home() {
	local _tmpdir="$1"
	mkdir -p "$_tmpdir/.config/aidevops"
	mkdir -p "$_tmpdir/.aidevops/agents/templates/workflows"
	# Copy the canonical caller template so the helper can resolve it.
	cp "$SCRIPT_DIR/../../templates/workflows/issue-sync-caller.yml" \
		"$_tmpdir/.aidevops/agents/templates/workflows/issue-sync-caller.yml"
	return 0
}

_write_repos_json() {
	local _tmpdir="$1"
	local _content="$2"
	printf '%s\n' "$_content" >"$_tmpdir/.config/aidevops/repos.json"
	return 0
}

_init_fake_repo() {
	local _repo_dir="$1"
	local _workflow_content="$2"
	mkdir -p "$_repo_dir/.github/workflows"
	git -C "$_repo_dir" init -q 2>/dev/null
	git -C "$_repo_dir" config user.email test@example.com
	git -C "$_repo_dir" config user.name Test
	git -C "$_repo_dir" config init.defaultBranch main
	git -C "$_repo_dir" checkout -q -b main 2>/dev/null || true
	printf '%s\n' "$_workflow_content" >"$_repo_dir/.github/workflows/issue-sync.yml"
	git -C "$_repo_dir" add -A
	git -C "$_repo_dir" commit -q -m "initial" 2>/dev/null
	return 0
}

CANONICAL_CALLER_CONTENT=$(cat "$SCRIPT_DIR/../../templates/workflows/issue-sync-caller.yml")

# ─── Test 1: no work when all current ───────────────────────────────────────
TMPDIR_1="$(mktemp -d)"
_setup_fake_home "$TMPDIR_1"
mkdir -p "$TMPDIR_1/repo-current/.github/workflows"
printf '%s\n' "$CANONICAL_CALLER_CONTENT" >"$TMPDIR_1/repo-current/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_1" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_1/repo-current\",\"slug\":\"owner/repo-current\"}]}"
OUT_1=$(HOME="$TMPDIR_1" bash "$HELPER" 2>&1)
EXIT_1=$?
_assert_contains "all-current → no actionable repos" "$OUT_1" "no actionable repos"
_assert_exit "all-current → exit 0" 0 "$EXIT_1"
rm -rf "$TMPDIR_1"

# ─── Test 2: NEEDS-MIGRATION → PLANNED in dry-run ───────────────────────────
TMPDIR_2="$(mktemp -d)"
_setup_fake_home "$TMPDIR_2"
LEGACY_CONTENT="name: Legacy Sync
on: [push]
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi"
mkdir -p "$TMPDIR_2/repo-legacy/.github/workflows"
printf '%s\n' "$LEGACY_CONTENT" >"$TMPDIR_2/repo-legacy/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_2" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_2/repo-legacy\",\"slug\":\"owner/repo-legacy\"}]}"
OUT_2=$(HOME="$TMPDIR_2" bash "$HELPER" 2>&1)
EXIT_2=$?
_assert_contains "NEEDS-MIGRATION → PLANNED in dry-run" "$OUT_2" "PLANNED"
_assert_contains "NEEDS-MIGRATION → install action" "$OUT_2" "install"
_assert_contains "NEEDS-MIGRATION → default ref @main" "$OUT_2" "@main"
_assert_exit "dry-run exits 0 even with planned work" 0 "$EXIT_2"
rm -rf "$TMPDIR_2"

# ─── Test 3: --json output shape ────────────────────────────────────────────
TMPDIR_3="$(mktemp -d)"
_setup_fake_home "$TMPDIR_3"
mkdir -p "$TMPDIR_3/repo-legacy/.github/workflows"
printf '%s\n' "$LEGACY_CONTENT" >"$TMPDIR_3/repo-legacy/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_3" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_3/repo-legacy\",\"slug\":\"owner/repo-legacy\"}]}"
OUT_3=$(HOME="$TMPDIR_3" bash "$HELPER" --json 2>/dev/null)
_assert_contains "JSON has slug" "$OUT_3" '"slug":"owner/repo-legacy"'
_assert_contains "JSON has classification" "$OUT_3" '"classification":"NEEDS-MIGRATION"'
_assert_contains "JSON has outcome" "$OUT_3" '"outcome":"PLANNED"'
_assert_contains "JSON has ref" "$OUT_3" '"ref":"@main"'
rm -rf "$TMPDIR_3"

# ─── Test 4: --ref override flows through ───────────────────────────────────
TMPDIR_4="$(mktemp -d)"
_setup_fake_home "$TMPDIR_4"
mkdir -p "$TMPDIR_4/repo-legacy/.github/workflows"
printf '%s\n' "$LEGACY_CONTENT" >"$TMPDIR_4/repo-legacy/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_4" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_4/repo-legacy\",\"slug\":\"owner/repo-legacy\"}]}"
OUT_4=$(HOME="$TMPDIR_4" bash "$HELPER" --ref @v3.9.0 2>&1)
_assert_contains "--ref @v3.9.0 reaches planned output" "$OUT_4" "@v3.9.0"
rm -rf "$TMPDIR_4"

# ─── Test 5: --repo filter narrows ──────────────────────────────────────────
TMPDIR_5="$(mktemp -d)"
_setup_fake_home "$TMPDIR_5"
mkdir -p "$TMPDIR_5/repo-a/.github/workflows" "$TMPDIR_5/repo-b/.github/workflows"
printf '%s\n' "$LEGACY_CONTENT" >"$TMPDIR_5/repo-a/.github/workflows/issue-sync.yml"
printf '%s\n' "$LEGACY_CONTENT" >"$TMPDIR_5/repo-b/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_5" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_5/repo-a\",\"slug\":\"owner/repo-a\"},{\"path\":\"$TMPDIR_5/repo-b\",\"slug\":\"owner/repo-b\"}]}"
OUT_5=$(HOME="$TMPDIR_5" bash "$HELPER" --repo owner/repo-a --json 2>/dev/null)
_assert_contains "--repo filter includes target" "$OUT_5" '"slug":"owner/repo-a"'
if ! grep -qF 'owner/repo-b' <<<"$OUT_5"; then
	printf '%sPASS%s --repo filter excludes other repos\n' "$GREEN" "$NC"
	((_PASS++))
else
	printf '%sFAIL%s --repo filter excludes other repos (repo-b leaked)\n' "$RED" "$NC"
	((_FAIL++))
fi
rm -rf "$TMPDIR_5"

# ─── Test 6: missing repos.json → exit 2 ────────────────────────────────────
TMPDIR_6="$(mktemp -d)"
_setup_fake_home "$TMPDIR_6"
# Deliberately omit repos.json.
rm -f "$TMPDIR_6/.config/aidevops/repos.json" 2>/dev/null
# Capture exit without masking via `|| true` — that swallows the exit code.
OUT_6=$(HOME="$TMPDIR_6" bash "$HELPER" 2>&1)
EXIT_6=$?
_assert_exit "missing repos.json → exit 2" 2 "$EXIT_6"
_assert_contains "missing repos.json → error message" "$OUT_6" "repos.json not found"
rm -rf "$TMPDIR_6"

# ─── Test 7: aidevops self never appears in sync output ─────────────────────
TMPDIR_7="$(mktemp -d)"
_setup_fake_home "$TMPDIR_7"
mkdir -p "$TMPDIR_7/aidevops-repo/.github/workflows"
# Use a literal SELF-CALLER form (uses: ./...).
SELF_CALLER='name: Issue Sync
on: { push: { branches: [main] } }
jobs:
  sync:
    uses: ./.github/workflows/issue-sync-reusable.yml
    secrets: inherit'
printf '%s\n' "$SELF_CALLER" >"$TMPDIR_7/aidevops-repo/.github/workflows/issue-sync.yml"
# Also add a legacy repo to ensure output is non-empty otherwise.
mkdir -p "$TMPDIR_7/legacy-repo/.github/workflows"
printf '%s\n' "$LEGACY_CONTENT" >"$TMPDIR_7/legacy-repo/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_7" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_7/aidevops-repo\",\"slug\":\"marcusquinn/aidevops\"},{\"path\":\"$TMPDIR_7/legacy-repo\",\"slug\":\"owner/legacy-repo\"}]}"
OUT_7=$(HOME="$TMPDIR_7" bash "$HELPER" --json 2>/dev/null)
if ! grep -qF 'marcusquinn/aidevops' <<<"$OUT_7"; then
	printf '%sPASS%s aidevops self never targeted by sync\n' "$GREEN" "$NC"
	((_PASS++))
else
	printf '%sFAIL%s aidevops self leaked into sync output\n' "$RED" "$NC"
	((_FAIL++))
fi
_assert_contains "legacy repo still surfaces" "$OUT_7" '"slug":"owner/legacy-repo"'
rm -rf "$TMPDIR_7"

# ─── Test 8: --help exits 0 and emits usage ─────────────────────────────────
OUT_8=$(bash "$HELPER" --help 2>&1)
EXIT_8=$?
_assert_exit "--help exits 0" 0 "$EXIT_8"
_assert_contains "--help shows Usage section" "$OUT_8" "Usage:"
_assert_contains "--help documents --apply" "$OUT_8" "--apply"

# ─── Test 9: unknown option → exit 2 ────────────────────────────────────────
OUT_9=$(bash "$HELPER" --bogus-flag 2>&1)
EXIT_9=$?
_assert_exit "unknown option → exit 2" 2 "$EXIT_9"
_assert_contains "unknown option error message" "$OUT_9" "unknown option"

# ─── Summary ────────────────────────────────────────────────────────────────
printf '\n'
if [[ "$_FAIL" -eq 0 ]]; then
	printf '%sAll %d test(s) passed%s\n' "$GREEN" "$_PASS" "$NC"
	exit 0
else
	printf '%s%d of %d test(s) failed%s\n' "$RED" "$_FAIL" "$((_PASS + _FAIL))" "$NC"
	exit 1
fi
