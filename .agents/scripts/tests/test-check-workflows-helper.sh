#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-check-workflows-helper.sh — fixture tests for check-workflows-helper.sh (t2778)
#
# Issue: GH#20648
#
# Scenarios covered:
#   1. No workflow file → classified NO-WORKFLOW
#   2. Self-caller (uses: ./...) → CURRENT/SELF-CALLER
#   3. Downstream caller @main → CURRENT/CALLER (byte-identical to canonical)
#   4. Downstream caller @v3.9.0 (pinned variant) → CURRENT/CALLER
#   5. Downstream caller with extra triggers → DRIFTED/CALLER
#   6. Legacy full-copy with issue-sync-helper.sh invocation → NEEDS-MIGRATION
#   7. Legacy full-copy without helper (inline logic) → NEEDS-MIGRATION
#   8. local_only repo → LOCAL-ONLY (no filesystem check)
#   9. repos.json missing → exit 2 with error
#  10. --repo filter narrows to one row
#  11. --json output parses as JSON
#
# Strategy: Each scenario writes a temporary repos.json + temporary repo trees
# under a per-test TMPDIR, points HOME at it, and invokes the helper. No
# network calls, no real GitHub API.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../check-workflows-helper.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
CANONICAL_TEMPLATE="$REPO_ROOT/.agents/templates/workflows/issue-sync-caller.yml"

if [[ ! -f "$HELPER" ]]; then
	echo "SKIP: helper not found at $HELPER" >&2
	exit 0
fi
if [[ ! -f "$CANONICAL_TEMPLATE" ]]; then
	echo "SKIP: canonical template not found at $CANONICAL_TEMPLATE" >&2
	exit 0
fi

readonly _T_GREEN='\033[0;32m'
readonly _T_RED='\033[0;31m'
readonly _T_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%bPASS%b %s\n' "$_T_GREEN" "$_T_RESET" "$name"
	return 0
}

_fail() {
	local name="$1"
	local msg="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%bFAIL%b %s\n' "$_T_RED" "$_T_RESET" "$name"
	[[ -n "$msg" ]] && printf '       %s\n' "$msg"
	return 0
}

# ─── Fixture helpers ────────────────────────────────────────────────────────

_setup_fake_home() {
	local _root="$1"
	# Directory layout mirrors the real aidevops install so the helper's
	# `_resolve_canonical_template` picks up the deployed copy.
	mkdir -p "$_root/.config/aidevops"
	mkdir -p "$_root/.aidevops/agents/templates/workflows"
	cp "$CANONICAL_TEMPLATE" "$_root/.aidevops/agents/templates/workflows/issue-sync-caller.yml"
	return 0
}

_write_repos_json() {
	local _root="$1"
	local _json="$2"
	printf '%s\n' "$_json" > "$_root/.config/aidevops/repos.json"
	return 0
}

_make_repo_with_workflow() {
	local _path="$1"
	local _content="${2:-}"
	mkdir -p "$_path/.github/workflows"
	if [[ -n "$_content" ]]; then
		printf '%s' "$_content" > "$_path/.github/workflows/issue-sync.yml"
	fi
	return 0
}

# ─── Scenario runner ────────────────────────────────────────────────────────

# _run_and_classify <fake-home-root> [extra-args...]
# Emits the classification for the only (or --repo-filtered) row on stdout.
_run_and_classify() {
	local _root="$1"
	shift
	HOME="$_root" bash "$HELPER" --json "$@" 2>/dev/null \
		| jq -r 'select(.slug != "") | .classification' \
		| head -n 1
	return 0
}

# ─── Tests ──────────────────────────────────────────────────────────────────

# Test 1: No workflow file
TMPDIR_1="$(mktemp -d)"
_setup_fake_home "$TMPDIR_1"
mkdir -p "$TMPDIR_1/repos/test-repo"
_write_repos_json "$TMPDIR_1" \
	"$(jq -n --arg path "$TMPDIR_1/repos/test-repo" '{initialized_repos: [{slug: "x/no-wf", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_1")
if [[ "$result" == "NO-WORKFLOW" ]]; then
	_pass "missing workflow file → NO-WORKFLOW"
else
	_fail "missing workflow file → NO-WORKFLOW" "got: $result"
fi
rm -rf "$TMPDIR_1"

# Test 2: Self-caller
TMPDIR_2="$(mktemp -d)"
_setup_fake_home "$TMPDIR_2"
SELF_CALLER_YAML='name: Issue Sync

on: { push: { branches: [main] } }

jobs:
  sync:
    uses: ./.github/workflows/issue-sync-reusable.yml
    secrets: inherit
'
_make_repo_with_workflow "$TMPDIR_2/repos/aidevops-self" "$SELF_CALLER_YAML"
_write_repos_json "$TMPDIR_2" \
	"$(jq -n --arg path "$TMPDIR_2/repos/aidevops-self" '{initialized_repos: [{slug: "x/self", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_2")
if [[ "$result" == "CURRENT/SELF-CALLER" ]]; then
	_pass "self-caller (./...) → CURRENT/SELF-CALLER"
else
	_fail "self-caller (./...) → CURRENT/SELF-CALLER" "got: $result"
fi
rm -rf "$TMPDIR_2"

# Test 3: Downstream caller byte-identical to canonical
TMPDIR_3="$(mktemp -d)"
_setup_fake_home "$TMPDIR_3"
_make_repo_with_workflow "$TMPDIR_3/repos/downstream-current"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_3/repos/downstream-current/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_3" \
	"$(jq -n --arg path "$TMPDIR_3/repos/downstream-current" '{initialized_repos: [{slug: "x/current", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_3")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "byte-identical downstream caller → CURRENT/CALLER"
else
	_fail "byte-identical downstream caller → CURRENT/CALLER" "got: $result"
fi
rm -rf "$TMPDIR_3"

# Test 4: Downstream caller with version-pinned ref
TMPDIR_4="$(mktemp -d)"
_setup_fake_home "$TMPDIR_4"
_make_repo_with_workflow "$TMPDIR_4/repos/downstream-pinned"
sed 's|issue-sync-reusable\.yml@main|issue-sync-reusable.yml@v3.9.0|g' \
	"$CANONICAL_TEMPLATE" > "$TMPDIR_4/repos/downstream-pinned/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_4" \
	"$(jq -n --arg path "$TMPDIR_4/repos/downstream-pinned" '{initialized_repos: [{slug: "x/pinned", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_4")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "pinned @v3.9.0 caller → CURRENT/CALLER (normalised @ref)"
else
	_fail "pinned @v3.9.0 caller → CURRENT/CALLER (normalised @ref)" "got: $result"
fi
rm -rf "$TMPDIR_4"

# Test 5: Caller with extra triggers → DRIFTED/CALLER
TMPDIR_5="$(mktemp -d)"
_setup_fake_home "$TMPDIR_5"
_make_repo_with_workflow "$TMPDIR_5/repos/downstream-drifted"
# Take canonical and append a new trigger path
{
	cat "$CANONICAL_TEMPLATE"
	printf '\n# Local customisation — should trigger DRIFTED detection\n'
	printf '# (any content change after normalising @ref counts as drift)\n'
} > "$TMPDIR_5/repos/downstream-drifted/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_5" \
	"$(jq -n --arg path "$TMPDIR_5/repos/downstream-drifted" '{initialized_repos: [{slug: "x/drifted", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_5")
if [[ "$result" == "DRIFTED/CALLER" ]]; then
	_pass "caller with local modifications → DRIFTED/CALLER"
else
	_fail "caller with local modifications → DRIFTED/CALLER" "got: $result"
fi
rm -rf "$TMPDIR_5"

# Test 6: Legacy full-copy with issue-sync-helper.sh reference → NEEDS-MIGRATION
TMPDIR_6="$(mktemp -d)"
_setup_fake_home "$TMPDIR_6"
FULL_COPY_WITH_HELPER='name: Issue Sync

on: { push: { branches: [main] } }

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash .agents/scripts/issue-sync-helper.sh push
'
_make_repo_with_workflow "$TMPDIR_6/repos/legacy-full-copy" "$FULL_COPY_WITH_HELPER"
_write_repos_json "$TMPDIR_6" \
	"$(jq -n --arg path "$TMPDIR_6/repos/legacy-full-copy" '{initialized_repos: [{slug: "x/legacy", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_6")
if [[ "$result" == "NEEDS-MIGRATION" ]]; then
	_pass "legacy full-copy with helper ref → NEEDS-MIGRATION"
else
	_fail "legacy full-copy with helper ref → NEEDS-MIGRATION" "got: $result"
fi
rm -rf "$TMPDIR_6"

# Test 7: Legacy full-copy with inline parsing (no helper) → NEEDS-MIGRATION
TMPDIR_7="$(mktemp -d)"
_setup_fake_home "$TMPDIR_7"
# shellcheck disable=SC2016  # literal YAML content — no expansion wanted
FULL_COPY_INLINE='name: Issue Sync

on: { push: { branches: [main] } }

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          # Parse TODO.md for ref:GH# markers and create issues inline
          while IFS= read -r line; do
            echo "$line" | grep -oE "t[0-9]+"
          done < TODO.md
'
_make_repo_with_workflow "$TMPDIR_7/repos/legacy-inline" "$FULL_COPY_INLINE"
_write_repos_json "$TMPDIR_7" \
	"$(jq -n --arg path "$TMPDIR_7/repos/legacy-inline" '{initialized_repos: [{slug: "x/inline", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_7")
if [[ "$result" == "NEEDS-MIGRATION" ]]; then
	_pass "legacy inline-logic full-copy → NEEDS-MIGRATION"
else
	_fail "legacy inline-logic full-copy → NEEDS-MIGRATION" "got: $result"
fi
rm -rf "$TMPDIR_7"

# Test 8: local_only repo → LOCAL-ONLY (no filesystem check needed)
TMPDIR_8="$(mktemp -d)"
_setup_fake_home "$TMPDIR_8"
_write_repos_json "$TMPDIR_8" \
	"$(jq -n --arg path "$TMPDIR_8/repos/local-only-repo" '{initialized_repos: [{slug: "", path: $path, local_only: true}]}')"
result=$(_run_and_classify "$TMPDIR_8")
if [[ "$result" == "LOCAL-ONLY" ]]; then
	_pass "local_only: true → LOCAL-ONLY (no fs check)"
else
	_fail "local_only: true → LOCAL-ONLY (no fs check)" "got: $result"
fi
rm -rf "$TMPDIR_8"

# Test 9: repos.json missing → exit 2
TMPDIR_9="$(mktemp -d)"
mkdir -p "$TMPDIR_9/.config/aidevops"
mkdir -p "$TMPDIR_9/.aidevops/agents/templates/workflows"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_9/.aidevops/agents/templates/workflows/issue-sync-caller.yml"
# Deliberately omit repos.json
HOME="$TMPDIR_9" bash "$HELPER" >/dev/null 2>&1
exit_code=$?
if [[ "$exit_code" -eq 2 ]]; then
	_pass "missing repos.json → exit 2"
else
	_fail "missing repos.json → exit 2" "got exit code: $exit_code"
fi
rm -rf "$TMPDIR_9"

# Test 10: --repo + --workflow filters narrow to exactly one row
# Note: --repo alone returns one row per known workflow type (N rows for N
# managed workflows). Adding --workflow narrows to a single (repo×workflow)
# row — this tests both filter flags working in concert.
TMPDIR_10="$(mktemp -d)"
_setup_fake_home "$TMPDIR_10"
_make_repo_with_workflow "$TMPDIR_10/repos/a"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_10/repos/a/.github/workflows/issue-sync.yml"
_make_repo_with_workflow "$TMPDIR_10/repos/b"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_10/repos/b/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_10" \
	"$(jq -n \
		--arg pa "$TMPDIR_10/repos/a" \
		--arg pb "$TMPDIR_10/repos/b" \
		'{initialized_repos: [{slug: "x/a", path: $pa, local_only: false}, {slug: "x/b", path: $pb, local_only: false}]}')"
count=$(HOME="$TMPDIR_10" bash "$HELPER" --json --repo "x/a" --workflow "issue-sync" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$count" == "1" ]]; then
	_pass "--repo + --workflow filters narrow to single row"
else
	_fail "--repo + --workflow filters narrow to single row" "expected 1 row, got $count"
fi
rm -rf "$TMPDIR_10"

# Test 11: --json emits parseable JSON per row
TMPDIR_11="$(mktemp -d)"
_setup_fake_home "$TMPDIR_11"
_make_repo_with_workflow "$TMPDIR_11/repos/good"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_11/repos/good/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_11" \
	"$(jq -n --arg path "$TMPDIR_11/repos/good" '{initialized_repos: [{slug: "x/good", path: $path, local_only: false}]}')"
json_row=$(HOME="$TMPDIR_11" bash "$HELPER" --json 2>/dev/null | head -n 1)
if printf '%s' "$json_row" | jq -e '.slug and .path and .classification' >/dev/null 2>&1; then
	_pass "--json emits well-formed JSON per row"
else
	_fail "--json emits well-formed JSON per row" "got: $json_row"
fi
rm -rf "$TMPDIR_11"

# Test 12: downstream caller with branches: [develop] → CURRENT/CALLER
# Verifies the branch-filter normalisation: a repo whose default branch is `develop`
# (installed by sync-workflows with branches: [develop]) is not flagged as DRIFTED.
TMPDIR_12="$(mktemp -d)"
_setup_fake_home "$TMPDIR_12"
_make_repo_with_workflow "$TMPDIR_12/repos/downstream-develop"
# Take canonical and replace `branches: [main]` with `branches: [develop]`.
sed 's/branches: \[main\]/branches: [develop]/' \
	"$CANONICAL_TEMPLATE" > "$TMPDIR_12/repos/downstream-develop/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_12" \
	"$(jq -n --arg path "$TMPDIR_12/repos/downstream-develop" \
		'{initialized_repos: [{slug: "x/develop-repo", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_12")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "canonical caller with branches: [develop] → CURRENT/CALLER (normalised branch filter)"
else
	_fail "canonical caller with branches: [develop] → CURRENT/CALLER (normalised branch filter)" \
		"got: $result"
fi
rm -rf "$TMPDIR_12"

# ─── Summary ────────────────────────────────────────────────────────────────

echo
if (( TESTS_FAILED == 0 )); then
	printf '%bAll %d test(s) passed%b\n' "$_T_GREEN" "$TESTS_RUN" "$_T_RESET"
	exit 0
else
	printf '%b%d of %d test(s) failed%b\n' "$_T_RED" "$TESTS_FAILED" "$TESTS_RUN" "$_T_RESET"
	exit 1
fi
