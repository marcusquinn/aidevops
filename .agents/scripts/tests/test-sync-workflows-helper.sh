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

# ─── Test 10: apply-mode rewrites branches: [main] → [develop] for develop-branch repos ───
# Strategy: create a local git repo with develop as default branch + a local bare
# remote so push succeeds. Run --apply; verify the committed workflow has
# `branches: [develop]` even though the canonical template ships `branches: [main]`.
# Note: _sync_open_pr will fail (gh_create_pr unavailable) but _sync_write_commit_push
# will have already committed the file to the feature branch before that.
TMPDIR_10="$(mktemp -d)"
_setup_fake_home "$TMPDIR_10"
# Local bare remote so `git push` succeeds.
BARE_10="$TMPDIR_10/bare.git"
git init --bare -q "$BARE_10" 2>/dev/null
git -C "$BARE_10" symbolic-ref HEAD refs/heads/develop 2>/dev/null
REPO_10="$TMPDIR_10/repo-develop"
mkdir -p "$REPO_10/.github/workflows"
git -C "$REPO_10" init -q 2>/dev/null
git -C "$REPO_10" config user.email test@example.com
git -C "$REPO_10" config user.name Test
# Disable commit signing — test repos don't need signed commits and
# the global gpg/ssh key may be passphrase-protected (causing commit failure).
git -C "$REPO_10" config commit.gpgsign false
git -C "$REPO_10" config tag.gpgsign false
# Set initial branch to develop before the first commit (works on all git versions).
git -C "$REPO_10" symbolic-ref HEAD refs/heads/develop 2>/dev/null
# Legacy workflow to trigger NEEDS-MIGRATION classification.
printf '%s\n' "$LEGACY_CONTENT" >"$REPO_10/.github/workflows/issue-sync.yml"
git -C "$REPO_10" add -A >/dev/null
git -C "$REPO_10" commit -q -m "initial"
git -C "$REPO_10" remote add origin "$BARE_10" 2>/dev/null
git -C "$REPO_10" push -q origin develop 2>/dev/null
# Set refs/remotes/origin/HEAD so _sync_preflight resolves develop as default.
git -C "$REPO_10" fetch -q origin 2>/dev/null
git -C "$REPO_10" remote set-head origin develop 2>/dev/null
_write_repos_json "$TMPDIR_10" "{\"initialized_repos\":[{\"path\":\"$REPO_10\",\"slug\":\"owner/repo-develop\"}]}"
SYNC_BRANCH_10="chore/workflow-sync-$(date +%Y%m%d)"
HOME="$TMPDIR_10" bash "$HELPER" --apply 2>/dev/null || true
# Verify the committed file on the feature branch has branches: [develop].
WF_BRANCHES_10=$(git -C "$REPO_10" show "${SYNC_BRANCH_10}:.github/workflows/issue-sync.yml" 2>/dev/null \
	| grep -E "^\s+branches:" | head -1 || true)
if [[ "$WF_BRANCHES_10" == *"[develop]"* ]]; then
	printf '%sPASS%s apply-mode writes branches: [develop] for develop-branch repo\n' "$GREEN" "$NC"
	((_PASS++))
else
	printf '%sFAIL%s apply-mode writes branches: [develop] for develop-branch repo\n' "$RED" "$NC"
	printf '       got: %s\n' "$WF_BRANCHES_10"
	((_FAIL++))
fi
rm -rf "$TMPDIR_10"

# ─── Test 11: GH#21897 — CURRENT/CALLER + repos.json runner field is actionable ───
# Regression: when a caller workflow is byte-identical to the canonical template
# but `repos.json` carries a fresh `runner` field, the helper used to report
# "no actionable repos" forever. Cause: `_normalize_wf_for_compare` strips
# `runner:` lines before byte-comparison so a runner-only change never raises
# DRIFTED/CALLER, and the actionable filter only let DRIFTED/CALLER and
# NEEDS-MIGRATION through. `_needs_runner_sync` now closes that gap by post-
# filtering CURRENT/CALLER rows where the on-disk runner differs from
# repos.json. This test pins the contract: a runner-add must surface as
# PLANNED with classification CURRENT/CALLER preserved.
TMPDIR_11="$(mktemp -d)"
_setup_fake_home "$TMPDIR_11"
mkdir -p "$TMPDIR_11/repo-runneradd/.github/workflows"
# Canonical caller — no runner: line.
printf '%s\n' "$CANONICAL_CALLER_CONTENT" >"$TMPDIR_11/repo-runneradd/.github/workflows/issue-sync.yml"
# repos.json carries a runner field that has not been propagated to the file.
_write_repos_json "$TMPDIR_11" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_11/repo-runneradd\",\"slug\":\"owner/repo-runneradd\",\"runner\":\"ubuntu-latest-arm64\"}]}"
OUT_11=$(HOME="$TMPDIR_11" bash "$HELPER" --json 2>/dev/null)
_assert_contains "GH#21897 → CURRENT/CALLER + repos.json runner is actionable" "$OUT_11" '"slug":"owner/repo-runneradd"'
_assert_contains "GH#21897 → planned outcome on runner add" "$OUT_11" '"outcome":"PLANNED"'
_assert_contains "GH#21897 → CURRENT/CALLER classification preserved" "$OUT_11" '"classification":"CURRENT/CALLER"'
rm -rf "$TMPDIR_11"

# ─── Test 12: GH#21897 — CURRENT/CALLER + matching runner already injected → no work ───
# Inverse of Test 11. When the file already carries the runner that repos.json
# specifies, `_needs_runner_sync` returns false (match) and the row is skipped,
# so the helper falls through to "no actionable repos". Pins that the runner-
# detector does not over-trigger and resync workflows pointlessly on every
# `--apply` after the first.
TMPDIR_12="$(mktemp -d)"
_setup_fake_home "$TMPDIR_12"
mkdir -p "$TMPDIR_12/repo-runnerok/.github/workflows"
# Canonical caller WITH runner already injected at the canonical position
# (mirrors what `_inject_runner_in_content` produces — first key inside
# the existing `    with:` block).
PRE_INJECTED_CONTENT=$(printf '%s\n' "$CANONICAL_CALLER_CONTENT" \
	| sed -E 's|^(    with:)$|\1\n      runner: ubuntu-latest-arm64|')
printf '%s\n' "$PRE_INJECTED_CONTENT" >"$TMPDIR_12/repo-runnerok/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_12" "{\"initialized_repos\":[{\"path\":\"$TMPDIR_12/repo-runnerok\",\"slug\":\"owner/repo-runnerok\",\"runner\":\"ubuntu-latest-arm64\"}]}"
OUT_12=$(HOME="$TMPDIR_12" bash "$HELPER" 2>&1)
EXIT_12=$?
_assert_contains "GH#21897 → already-injected runner is no-op" "$OUT_12" "no actionable repos"
_assert_exit "GH#21897 → no-op exits 0" 0 "$EXIT_12"
rm -rf "$TMPDIR_12"

# ─── Test 13: GH#24520 — apply renders configured reusable repo/ref ─────────
TMPDIR_13="$(mktemp -d)"
_setup_fake_home "$TMPDIR_13"
BARE_13="$TMPDIR_13/bare.git"
git init --bare -q "$BARE_13" 2>/dev/null
REPO_13="$TMPDIR_13/repo-org-target"
mkdir -p "$REPO_13/.github/workflows"
git -C "$REPO_13" init -q 2>/dev/null
git -C "$REPO_13" config user.email test@example.com
git -C "$REPO_13" config user.name Test
git -C "$REPO_13" config commit.gpgsign false
git -C "$REPO_13" symbolic-ref HEAD refs/heads/main 2>/dev/null
printf '%s\n' "$LEGACY_CONTENT" >"$REPO_13/.github/workflows/issue-sync.yml"
git -C "$REPO_13" add -A >/dev/null
git -C "$REPO_13" commit -q -m "initial"
git -C "$REPO_13" remote add origin "$BARE_13" 2>/dev/null
git -C "$REPO_13" push -q origin main 2>/dev/null
git -C "$REPO_13" fetch -q origin 2>/dev/null
git -C "$REPO_13" remote set-head origin main 2>/dev/null
_write_repos_json "$TMPDIR_13" "{\"workflow_reusable_repo\":\"ORG/.github\",\"workflow_reusable_ref\":\"1234567890abcdef1234567890abcdef12345678\",\"initialized_repos\":[{\"path\":\"$REPO_13\",\"slug\":\"owner/repo-org-target\",\"runner\":\"ubuntu-latest-arm64\"}]}"
SYNC_BRANCH_13="chore/workflow-sync-$(date +%Y%m%d)"
HOME="$TMPDIR_13" bash "$HELPER" --apply 2>/dev/null || true
WF_USES_13=$(git -C "$REPO_13" show "${SYNC_BRANCH_13}:.github/workflows/issue-sync.yml" 2>/dev/null \
	| grep -E "^[[:space:]]+uses:" | head -n 1 || true)
WF_RUNNER_13=$(git -C "$REPO_13" show "${SYNC_BRANCH_13}:.github/workflows/issue-sync.yml" 2>/dev/null \
	| grep -E "^[[:space:]]+runner:" | head -n 1 || true)
if [[ "$WF_USES_13" == *"ORG/.github/.github/workflows/issue-sync-reusable.yml@1234567890abcdef1234567890abcdef12345678"* ]]; then
	printf '%sPASS%s GH#24520 apply writes configured org reusable target\n' "$GREEN" "$NC"
	((_PASS++))
else
	printf '%sFAIL%s GH#24520 apply writes configured org reusable target\n' "$RED" "$NC"
	printf '       got: %s\n' "$WF_USES_13"
	((_FAIL++))
fi
if [[ "$WF_RUNNER_13" == *"ubuntu-latest-arm64"* ]]; then
	printf '%sPASS%s GH#24520 runner injection survives configured org target\n' "$GREEN" "$NC"
	((_PASS++))
else
	printf '%sFAIL%s GH#24520 runner injection survives configured org target\n' "$RED" "$NC"
	printf '       got: %s\n' "$WF_RUNNER_13"
	((_FAIL++))
fi
rm -rf "$TMPDIR_13"

# ─── Summary ────────────────────────────────────────────────────────────────
printf '\n'
if [[ "$_FAIL" -eq 0 ]]; then
	printf '%sAll %d test(s) passed%s\n' "$GREEN" "$_PASS" "$NC"
	exit 0
else
	printf '%s%d of %d test(s) failed%s\n' "$RED" "$_FAIL" "$((_PASS + _FAIL))" "$NC"
	exit 1
fi
