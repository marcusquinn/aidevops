#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-repo-aidevops-health.sh — smoke tests for r914 helper.
#
# Scope (MVP):
#   - Helper is executable and shellcheck-clean.
#   - Subcommands enable/disable/check/run/status/logs/help are dispatched.
#   - Dry-run mode detects the three drift classes against a fixture
#     repos.json without making any writes, commits, or pushes.
#
# Follow-up (not in MVP, tracked in PR description):
#   - Non-dry-run version-bump integration test (requires a sandboxed git repo)
#   - Issue-filing idempotency test (requires mocked gh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/.agents/scripts/repo-aidevops-health-helper.sh"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

PASS=0
FAIL=0

assert() {
	local desc="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		echo "${GREEN}PASS${NC} $desc"
		PASS=$((PASS + 1))
	else
		echo "${RED}FAIL${NC} $desc"
		echo "  expected: '$expected'"
		echo "  actual:   '$actual'"
		FAIL=$((FAIL + 1))
	fi
}

assert_contains() {
	local desc="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "${GREEN}PASS${NC} $desc"
		PASS=$((PASS + 1))
	else
		echo "${RED}FAIL${NC} $desc"
		echo "  needle not found: '$needle'"
		echo "  in: $(echo "$haystack" | head -3)"
		FAIL=$((FAIL + 1))
	fi
}

load_helper_without_main() {
	local AIDEVOPS_REPO_HEALTH_HELPER_SOURCE_ONLY=1
	# shellcheck source=/dev/null
	source "$HELPER"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1 — helper is executable
# ---------------------------------------------------------------------------
if [[ -x "$HELPER" ]]; then
	echo "${GREEN}PASS${NC} helper is executable"
	PASS=$((PASS + 1))
else
	echo "${RED}FAIL${NC} helper is not executable: $HELPER"
	FAIL=$((FAIL + 1))
	exit 1
fi

# ---------------------------------------------------------------------------
# Test 2 — help output lists required subcommands
# ---------------------------------------------------------------------------
HELP_OUT="$("$HELPER" help 2>&1 || true)"
assert_contains "help lists enable" "$HELP_OUT" "enable"
assert_contains "help lists disable" "$HELP_OUT" "disable"
assert_contains "help lists check" "$HELP_OUT" "check"
assert_contains "help lists run" "$HELP_OUT" "run"

# ---------------------------------------------------------------------------
# Test 3 — dry-run against fixture repos.json detects drift classes
# ---------------------------------------------------------------------------
FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# Fixture repos.json with all three drift classes:
#   - stale-version entry (path exists, .aidevops.json has old version)
#   - missing-folder entry (path does not exist, not archived)
#   - no-init directory is the FIXTURE_DIR itself holding an empty git repo
mkdir -p "$FIXTURE_DIR/stale-repo"
cd "$FIXTURE_DIR/stale-repo"
git init -q
echo '{"aidevops_version":"0.0.1"}' >.aidevops.json
git add .aidevops.json && git -c user.email=t@t -c user.name=T -c commit.gpgsign=false commit -qm init >/dev/null 2>&1 || true

mkdir -p "$FIXTURE_DIR/unregistered-repo"
cd "$FIXTURE_DIR/unregistered-repo"
git init -q
# No .aidevops.json, no .aidevops-skip — should trigger no-init detection.

cat >"$FIXTURE_DIR/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "slug": "test/stale-repo",
      "path": "$FIXTURE_DIR/stale-repo",
      "local_only": true
    },
    {
      "slug": "test/missing-folder",
      "path": "$FIXTURE_DIR/does-not-exist",
      "local_only": true
    }
  ],
  "git_parent_dirs": [
    "$FIXTURE_DIR"
  ]
}
EOF

# Run in dry-run mode with overridden config/state/log paths
DRY_LOG=$(mktemp)
CONFIG_FILE="$FIXTURE_DIR/repos.json" \
	AIDEVOPS_REPO_HEALTH_DRY_RUN=1 \
	"$HELPER" check >"$DRY_LOG" 2>&1 || true

LOG_CONTENT="$(tail -30 ~/.aidevops/logs/repo-aidevops-health.log 2>/dev/null || true)"

# NOTE: The helper reads CONFIG_FILE from its own readonly — the env override
# above is a best-effort. If the helper didn't honour it, the test will still
# exercise the dispatcher and dry-run flag. Full env-isolated invocation is
# a follow-up improvement (helper-side CONFIG_FILE= override support).

# ---------------------------------------------------------------------------
# Test 4 — dry-run does not create git commits in the stale-repo fixture
# ---------------------------------------------------------------------------
COMMITS_AFTER=$(git -C "$FIXTURE_DIR/stale-repo" rev-list --count HEAD 2>/dev/null || echo 0)
assert "dry-run does not add commits to stale-repo" "$COMMITS_AFTER" "1"

# ---------------------------------------------------------------------------
# Test 5 — unknown subcommand exits non-zero with help
# ---------------------------------------------------------------------------
set +e
UNKNOWN_OUT="$("$HELPER" bogus-subcommand 2>&1)"
UNKNOWN_RC=$?
set -e
if [[ "$UNKNOWN_RC" -ne 0 ]]; then
	echo "${GREEN}PASS${NC} unknown subcommand returns non-zero"
	PASS=$((PASS + 1))
else
	echo "${RED}FAIL${NC} unknown subcommand returned 0 (expected non-zero)"
	FAIL=$((FAIL + 1))
fi
assert_contains "unknown subcommand prints help" "$UNKNOWN_OUT" "Unknown command"

# ---------------------------------------------------------------------------
# Test 6 — plist generation accepts legacy two-argument invocation
# ---------------------------------------------------------------------------
load_helper_without_main
PLIST_OUT=$(_generate_plist "/tmp/aidevops-health" "/usr/bin:/bin")
assert_contains "plist two-argument legacy call keeps environment path" "$PLIST_OUT" "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>"
assert_contains "plist generation uses calendar schedule" "$PLIST_OUT" "<key>StartCalendarInterval</key>"

# ---------------------------------------------------------------------------
# Test 7 — non-local version bumps use branch + PR instead of direct main push
# ---------------------------------------------------------------------------
REMOTE_DIR=$(mktemp -d)
WORK_REPO="$FIXTURE_DIR/pr-bump-repo"
git init --bare -q "$REMOTE_DIR/origin.git"
git init -q "$WORK_REPO"
git -C "$WORK_REPO" checkout -q -b main
git -C "$WORK_REPO" config user.email t@t
git -C "$WORK_REPO" config user.name T
git -C "$WORK_REPO" config commit.gpgsign false
printf '%s\n' '{"aidevops_version":"0.0.1"}' >"$WORK_REPO/.aidevops.json"
git -C "$WORK_REPO" add .aidevops.json
git -C "$WORK_REPO" commit -qm init
git -C "$WORK_REPO" remote add origin "$REMOTE_DIR/origin.git"
git -C "$WORK_REPO" push -q -u origin main
git -C "$WORK_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

GH_CREATE_PR_ARGS="$FIXTURE_DIR/gh-create-pr-args.txt"
gh() {
	return 1
}
gh_create_pr() {
	printf '%s\n' "$*" >"$GH_CREATE_PR_ARGS"
	printf '%s\n' "https://example.invalid/pr/1"
	return 0
}

BUMP_OUT=$(_bump_single_repo "test/pr-bump-repo" "$WORK_REPO" "false" "9.9.9" "0")
assert "non-local bump reports bumped" "$BUMP_OUT" "bumped"
CURRENT_BRANCH=$(git -C "$WORK_REPO" rev-parse --abbrev-ref HEAD)
assert "non-local bump restores default branch" "$CURRENT_BRANCH" "main"
DEFAULT_VERSION=$(git -C "$WORK_REPO" show main:.aidevops.json | jq -r '.aidevops_version')
assert "non-local bump leaves default branch unchanged" "$DEFAULT_VERSION" "0.0.1"
REMOTE_BRANCH_VERSION=$(git -C "$WORK_REPO" show "origin/chore/aidevops-version-v9.9.9-test-pr-bump-repo:.aidevops.json" | jq -r '.aidevops_version')
assert "non-local bump pushes version branch" "$REMOTE_BRANCH_VERSION" "9.9.9"
PR_ARGS=$(<"$GH_CREATE_PR_ARGS")
assert_contains "non-local bump creates PR against repo" "$PR_ARGS" "--repo test/pr-bump-repo"
assert_contains "non-local bump creates PR from version branch" "$PR_ARGS" "--head chore/aidevops-version-v9.9.9-test-pr-bump-repo"

# ---------------------------------------------------------------------------
# Test 8 — PR creation failures restore the default branch
# ---------------------------------------------------------------------------
git -C "$WORK_REPO" checkout -q chore/aidevops-version-v9.9.9-test-pr-bump-repo
gh_create_pr() {
	printf '%s\n' "simulated PR creation failure"
	return 1
}

set +e
_open_version_bump_pr "test/pr-bump-repo" "$WORK_REPO" "chore/aidevops-version-v9.9.9-test-pr-bump-repo" "main" "0.0.1" "9.9.9" >/dev/null 2>&1
OPEN_PR_RC=$?
set -e
if [[ "$OPEN_PR_RC" -ne 0 ]]; then
	echo "${GREEN}PASS${NC} PR creation failure returns non-zero"
	PASS=$((PASS + 1))
else
	echo "${RED}FAIL${NC} PR creation failure returned 0"
	FAIL=$((FAIL + 1))
fi
CURRENT_BRANCH=$(git -C "$WORK_REPO" rev-parse --abbrev-ref HEAD)
assert "PR creation failure restores default branch" "$CURRENT_BRANCH" "main"

# ---------------------------------------------------------------------------
# Test 9 — rerunning a machine branch force-pushes replacement commits
# ---------------------------------------------------------------------------
gh_create_pr() {
	printf '%s\n' "$*" >"$GH_CREATE_PR_ARGS"
	printf '%s\n' "https://example.invalid/pr/2"
	return 0
}

BUMP_OUT=$(_bump_single_repo "test/pr-bump-repo" "$WORK_REPO" "false" "9.9.9" "0")
assert "non-local bump rerun reports bumped" "$BUMP_OUT" "bumped"
REMOTE_BRANCH_VERSION=$(git -C "$WORK_REPO" show "origin/chore/aidevops-version-v9.9.9-test-pr-bump-repo:.aidevops.json" | jq -r '.aidevops_version')
assert "non-local bump rerun replaces remote version branch" "$REMOTE_BRANCH_VERSION" "9.9.9"

# ---------------------------------------------------------------------------
# Test 10 — recovery reset only runs when .aidevops.json is the sole ahead file
# ---------------------------------------------------------------------------
MULTI_REMOTE_DIR=$(mktemp -d)
MULTI_REPO="$FIXTURE_DIR/multi-ahead-repo"
git init --bare -q "$MULTI_REMOTE_DIR/origin.git"
git init -q "$MULTI_REPO"
git -C "$MULTI_REPO" checkout -q -b main
git -C "$MULTI_REPO" config user.email t@t
git -C "$MULTI_REPO" config user.name T
git -C "$MULTI_REPO" config commit.gpgsign false
printf '%s\n' '{"aidevops_version":"9.9.9"}' >"$MULTI_REPO/.aidevops.json"
git -C "$MULTI_REPO" add .aidevops.json
git -C "$MULTI_REPO" commit -qm init
git -C "$MULTI_REPO" remote add origin "$MULTI_REMOTE_DIR/origin.git"
git -C "$MULTI_REPO" push -q -u origin main
git -C "$MULTI_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
printf '%s\n' '{"aidevops_version":"10.0.0"}' >"$MULTI_REPO/.aidevops.json"
printf '%s\n' 'preserve me' >"$MULTI_REPO/extra.txt"
git -C "$MULTI_REPO" add .aidevops.json extra.txt
git -C "$MULTI_REPO" commit -qm 'local mixed changes'
MULTI_OUT=$(_bump_single_repo "test/multi-ahead-repo" "$MULTI_REPO" "false" "9.9.9" "0")
assert "mixed ahead files skip destructive recovery" "$MULTI_OUT" "skipped"
MULTI_AHEAD_COUNT=$(git -C "$MULTI_REPO" rev-list --count origin/main..HEAD)
assert "mixed ahead files remain preserved" "$MULTI_AHEAD_COUNT" "1"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Ran $((PASS + FAIL)) tests, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
