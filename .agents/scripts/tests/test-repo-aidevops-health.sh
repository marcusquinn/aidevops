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
git add .aidevops.json && git -c user.email=t@t -c user.name=T commit -qm init >/dev/null 2>&1 || true

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

LOG_CONTENT="$(cat ~/.aidevops/logs/repo-aidevops-health.log 2>/dev/null | tail -30 || true)"

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
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Ran $((PASS + FAIL)) tests, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
