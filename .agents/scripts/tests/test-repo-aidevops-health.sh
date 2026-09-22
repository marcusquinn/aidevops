#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for the r914 project-config health keeper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/.agents/scripts/repo-aidevops-health-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'
PASS=0
FAIL=0

pass() {
	local desc="$1"
	printf '%sPASS%s %s\n' "$GREEN" "$NC" "$desc"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local desc="$1"
	local detail="$2"
	printf '%sFAIL%s %s — %s\n' "$RED" "$NC" "$desc" "$detail" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_equal() {
	local desc="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc" "expected='$expected' actual='$actual'"
	fi
	return 0
}

assert_contains() {
	local desc="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$desc"
	else
		fail "$desc" "missing '$needle'"
	fi
	return 0
}

file_mode() {
	local path="$1"
	if stat -f '%Lp' "$path" >/dev/null 2>&1; then
		stat -f '%Lp' "$path"
	else
		stat -c '%a' "$path"
	fi
	return 0
}

count_migration_plans() {
	local plan_dir="$HOME/.aidevops/.agent-workspace/work"
	local plans=()
	shopt -s nullglob
	plans=("$plan_dir"/project-config-migration-*.json)
	shopt -u nullglob
	printf '%s\n' "${#plans[@]}"
	return 0
}

init_fixture_repo() {
	local repo="$1"
	/usr/bin/git -C "$repo" init -q -b fixture
	/usr/bin/git -C "$repo" config user.email test@example.invalid
	/usr/bin/git -C "$repo" config user.name Test
	/usr/bin/git -C "$repo" config commit.gpgsign false
	printf '%s\n' '.aidevops.json' >"$repo/.gitignore"
	/usr/bin/git -C "$repo" add .gitignore
	/usr/bin/git -C "$repo" commit -qm fixture
	return 0
}

if [[ -x "$HELPER" ]]; then
	pass "helper is executable"
else
	fail "helper is executable" "$HELPER is not executable"
	exit 1
fi

HELP_OUT="$($HELPER help 2>&1 || true)"
assert_contains "help lists enable" "$HELP_OUT" "enable"
assert_contains "help lists disable" "$HELP_OUT" "disable"
assert_contains "help lists check" "$HELP_OUT" "check"
assert_contains "help describes local metadata safety" "$HELP_OUT" "Never commits, branches, pushes, or opens PRs"

export HOME="$TEST_ROOT/home"
CONFIG_DIR="$HOME/.config/aidevops"
mkdir -p "$CONFIG_DIR" "$HOME/.aidevops/agents"
ln -s "$REPO_ROOT/.agents/configs" "$HOME/.aidevops/agents/configs"
export AIDEVOPS_TEMP_DIR="$HOME/.aidevops/.agent-workspace/work"
mkdir -p "$AIDEVOPS_TEMP_DIR"
printf '%s\n' '9.9.9' >"$HOME/.aidevops/agents/VERSION"

STALE_REPO="$TEST_ROOT/stale-repo"
CURRENT_REPO="$TEST_ROOT/current-repo"
TRACKED_REPO="$TEST_ROOT/tracked-repo"
REGISTERED_MISSING_REPO="$TEST_ROOT/registered-missing-repo"
UNREGISTERED_REPO="$TEST_ROOT/unregistered-repo"
mkdir -p "$STALE_REPO" "$CURRENT_REPO" "$TRACKED_REPO" "$REGISTERED_MISSING_REPO" "$UNREGISTERED_REPO"

printf '%s\n' '{"version":"0.0.1","features":{"planning":true}}' >"$STALE_REPO/.aidevops.json"
chmod 600 "$STALE_REPO/.aidevops.json"
printf '%s\n' '{"version":"9.9.9","features":{"planning":false}}' >"$CURRENT_REPO/.aidevops.json"
printf '%s\n' '{"version":"0.0.1","features":{"planning":true}}' >"$TRACKED_REPO/.aidevops.json"

for fixture_repo in "$STALE_REPO" "$CURRENT_REPO" "$TRACKED_REPO" "$REGISTERED_MISSING_REPO" "$UNREGISTERED_REPO"; do
	init_fixture_repo "$fixture_repo"
done
/usr/bin/git -C "$TRACKED_REPO" add -f .aidevops.json
/usr/bin/git -C "$TRACKED_REPO" commit -qm tracked-config

jq -n \
	--arg stale "$STALE_REPO" \
	--arg current "$CURRENT_REPO" \
	--arg tracked "$TRACKED_REPO" \
	--arg registered_missing "$REGISTERED_MISSING_REPO" \
	--arg missing_folder "$TEST_ROOT/does-not-exist" \
	--arg disabled "$TEST_ROOT/disabled-existing" \
	--arg parent "$TEST_ROOT" \
	'{
		initialized_repos: [
			{slug:"test/stale",path:$stale},
			{slug:"test/current",path:$current},
			{slug:"test/tracked",path:$tracked},
			{slug:"test/registered-missing",path:$registered_missing},
			{slug:"test/missing-folder",path:$missing_folder},
			{slug:"test/disabled",path:$disabled,maintenance:false}
		],
		git_parent_dirs: [$parent]
	}' >"$CONFIG_DIR/repos.json"
mkdir -p "$TEST_ROOT/disabled-existing"

TRACKED_BEFORE=$(cksum <"$TRACKED_REPO/.aidevops.json")
CURRENT_BEFORE=$(cksum <"$CURRENT_REPO/.aidevops.json")
STALE_MODE_BEFORE=$(file_mode "$STALE_REPO/.aidevops.json")
STALE_HEAD_BEFORE=$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)
EXPECTED_FIRST_SUMMARY="1 bumped, 2 bump-skipped, 0 bump-failed, 1 registered-config-missing, 1 missing-folder, 1 no-init"
HEALTH_LOG="$HOME/.aidevops/logs/repo-aidevops-health.log"

AIDEVOPS_REPO_HEALTH_DRY_RUN=1 "$HELPER" check >/dev/null 2>&1
assert_contains "dry run distinguishes every drift class" "$(<"$HEALTH_LOG")" "$EXPECTED_FIRST_SUMMARY"
assert_equal "dry run preserves stale version" "$(jq -r '.version' "$STALE_REPO/.aidevops.json")" "0.0.1"
assert_equal "dry run does not write tracked migration plan" "$(count_migration_plans)" "0"

"$HELPER" check >/dev/null 2>&1
assert_contains "real run distinguishes every drift class" "$(<"$HEALTH_LOG")" "$EXPECTED_FIRST_SUMMARY"
assert_equal "stale local config advances canonical version" "$(jq -r '.version' "$STALE_REPO/.aidevops.json")" "9.9.9"
assert_equal "local config does not gain legacy version key" "$(jq -r 'has("aidevops_version")' "$STALE_REPO/.aidevops.json")" "false"
assert_equal "local config preserves feature choices" "$(jq -r '.features.planning' "$STALE_REPO/.aidevops.json")" "true"
assert_equal "local config preserves file mode" "$(file_mode "$STALE_REPO/.aidevops.json")" "$STALE_MODE_BEFORE"
assert_equal "current local config remains byte-identical" "$(cksum <"$CURRENT_REPO/.aidevops.json")" "$CURRENT_BEFORE"
assert_equal "local config update does not create a commit" "$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)" "$STALE_HEAD_BEFORE"
assert_equal "ignored local config keeps repository clean" "$(/usr/bin/git -C "$STALE_REPO" status --porcelain)" ""
assert_equal "tracked config remains byte-identical" "$(cksum <"$TRACKED_REPO/.aidevops.json")" "$TRACKED_BEFORE"
assert_equal "tracked config emits one migration plan" "$(count_migration_plans)" "1"
assert_equal "registered missing config is not created" "$(test -e "$REGISTERED_MISSING_REPO/.aidevops.json" && printf yes || printf no)" "no"

STATUS_OUT=$("$HELPER" status 2>&1)
assert_contains "status reports bump counters" "$STATUS_OUT" "1 bumped, 2 bump-skipped, 0 bump-failed"
assert_contains "status reports drift counters" "$STATUS_OUT" "1 registered-config-missing, 1 missing-folder, 1 no-init"

"$HELPER" check >/dev/null 2>&1
assert_contains "rerun is idempotent" "$(<"$HEALTH_LOG")" "0 bumped, 3 bump-skipped, 0 bump-failed, 1 registered-config-missing, 1 missing-folder, 1 no-init"
assert_equal "rerun keeps one migration plan" "$(count_migration_plans)" "1"

set +e
UNKNOWN_OUT=$("$HELPER" bogus-subcommand 2>&1)
UNKNOWN_RC=$?
set -e
if [[ "$UNKNOWN_RC" -ne 0 ]]; then
	pass "unknown subcommand returns non-zero"
else
	fail "unknown subcommand returns non-zero" "exit=$UNKNOWN_RC"
fi
assert_contains "unknown subcommand prints help" "$UNKNOWN_OUT" "Unknown command"

AIDEVOPS_REPO_HEALTH_HELPER_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$HELPER"
PLIST_OUT=$(_generate_plist "/tmp/aidevops-health" "/usr/bin:/bin")
assert_contains "plist legacy call keeps environment path" "$PLIST_OUT" "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>"
assert_contains "plist generation uses calendar schedule" "$PLIST_OUT" "<key>StartCalendarInterval</key>"
assert_equal "shared accessor reads canonical version" "$(_project_config_read_version "$STALE_REPO/.aidevops.json")" "9.9.9"

printf '\nRan %d tests, %d failed.\n' "$((PASS + FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]]
