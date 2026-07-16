#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

passed=0
failed=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	passed=$((passed + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf 'FAIL: %s — %s\n' "$name" "$detail" >&2
	failed=$((failed + 1))
	return 0
}

assert_equal() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected=${expected} actual=${actual}"
	fi
	return 0
}

make_repo() {
	local repo="$1"
	local tracked="$2"
	mkdir -p "$repo"
	/usr/bin/git -C "$repo" init -q -b main
	/usr/bin/git -C "$repo" config user.email test@example.invalid
	/usr/bin/git -C "$repo" config user.name Test
	/usr/bin/git -C "$repo" config commit.gpgsign false
	printf '%s\n' '{"version":"0.0.1","features":{"planning":true}}' >"$repo/.aidevops.json"
	if [[ "$tracked" == "true" ]]; then
		/usr/bin/git -C "$repo" add .aidevops.json
	else
		printf '%s\n' '.aidevops.json' >"$repo/.gitignore"
		/usr/bin/git -C "$repo" add .gitignore
	fi
	/usr/bin/git -C "$repo" commit -qm fixture
	return 0
}

export HOME="${TEST_ROOT}/home"
INSTALL_DIR="$REPO_ROOT"
AGENTS_DIR="$REPO_ROOT/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
REPOS_FILE="${CONFIG_DIR}/repos.json"
mkdir -p "$CONFIG_DIR"

print_header() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
get_version() {
	printf '9.9.9\n'
	return 0
}

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"
# shellcheck source=../aidevops-cli/aidevops-update-lib.sh
source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"

_repo_registration_maintainer() {
	printf '\n'
	return 0
}
seed_agent_source_repo_templates() { return 0; }

tracked_repo="${TEST_ROOT}/tracked"
local_repo="${TEST_ROOT}/local"
make_repo "$tracked_repo" true
make_repo "$local_repo" false
tracked_repo="$(cd "$tracked_repo" && pwd -P)"
local_repo="$(cd "$local_repo" && pwd -P)"

jq -n --arg tracked "$tracked_repo" --arg local "$local_repo" '{
	initialized_repos: [
		{path: $tracked, version: "0.0.1", features: ["planning"], agent_source: true},
		{path: $local, version: "0.0.1", features: ["planning"]}
	],
	git_parent_dirs: []
}' >"$REPOS_FILE"

get_agent_source_repos() {
	printf '%s\n' "$tracked_repo"
	return 0
}

tracked_before=$(cksum <"$tracked_repo/.aidevops.json")
_update_sync_projects false 9.9.9
tracked_after=$(cksum <"$tracked_repo/.aidevops.json")

assert_equal "tracked config remains byte-identical" "$tracked_before" "$tracked_after"
assert_equal "tracked repository remains clean" "" "$(/usr/bin/git -C "$tracked_repo" status --porcelain)"
assert_equal "tracked config does not gain agent-source metadata" "false" "$(jq -r 'has("agent_source")' "$tracked_repo/.aidevops.json")"
assert_equal "tracked registration advances" "9.9.9" "$(jq -r --arg path "$tracked_repo" '.initialized_repos[] | select(.path == $path) | .version' "$REPOS_FILE")"
assert_equal "tracked registration preserves features" "planning" "$(jq -r --arg path "$tracked_repo" '.initialized_repos[] | select(.path == $path) | .features | join(",")' "$REPOS_FILE")"
assert_equal "local config version advances" "9.9.9" "$(jq -r '.version' "$local_repo/.aidevops.json")"
assert_equal "local registration advances" "9.9.9" "$(jq -r --arg path "$local_repo" '.initialized_repos[] | select(.path == $path) | .version' "$REPOS_FILE")"
assert_equal "local repository remains clean" "" "$(/usr/bin/git -C "$local_repo" status --porcelain)"

printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
[[ "$failed" -eq 0 ]]
