#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

# Resolve native Git once from the system default PATH (portable to non-FHS
# hosts such as NixOS); fixtures must bypass the aidevops git wrapper.
TEST_NATIVE_GIT=$(command -p -v git) || {
	printf '%s\n' 'Native Git is unavailable on the system PATH' >&2
	exit 1
}
export TEST_NATIVE_GIT

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
	"$TEST_NATIVE_GIT" -C "$repo" init -q -b main
	"$TEST_NATIVE_GIT" -C "$repo" config user.email test@example.invalid
	"$TEST_NATIVE_GIT" -C "$repo" config user.name Test
	"$TEST_NATIVE_GIT" -C "$repo" config commit.gpgsign false
	printf '%s\n' '{"version":"0.0.1","features":{"planning":true}}' >"$repo/.aidevops.json"
	if [[ "$tracked" == "true" ]]; then
		printf '%s\n' '.aidevops.json' >"$repo/.gitignore"
		"$TEST_NATIVE_GIT" -C "$repo" add -f .aidevops.json
		"$TEST_NATIVE_GIT" -C "$repo" add .gitignore
	else
		printf '%s\n' '.aidevops.json' >"$repo/.gitignore"
		"$TEST_NATIVE_GIT" -C "$repo" add .gitignore
	fi
	"$TEST_NATIVE_GIT" -C "$repo" commit -qm fixture
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
# Every framework release re-enters the tracked-config migration path, so later
# runs advance this version instead of replaying an already-registered one.
TEST_RELEASE_VERSION="9.9.9"
get_version() {
	printf '%s\n' "$TEST_RELEASE_VERSION"
	return 0
}
update_for_next_release() {
	local version="$1"
	TEST_RELEASE_VERSION="$version"
	_update_sync_projects false "$version"
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

# The project-config library delegates the collaborator check and GitHub write;
# make the fixture deterministic without contacting GitHub.
_project_config_can_file_migration() {
	[[ "$1" == "example/maintained" ]]
	return $?
}
_project_config_repo_slug() {
	case "$1" in
	*tracked) printf 'example/maintained' ;;
	*) printf 'example/external' ;;
	esac
	return 0
}
_project_config_migration_exists() {
	[[ -f "${TEST_ROOT}/migration-lookup-fails" ]] && return 2
	[[ -f "${TEST_ROOT}/migration-created" ]]
	return $?
}
_project_config_remote_tracks_config() {
	[[ ! -f "${TEST_ROOT}/remote-migrated" ]]
	return $?
}
_project_config_write_migration_issue() {
	touch "${TEST_ROOT}/migration-created"
	printf '%s\n' "$1" >>"${TEST_ROOT}/migration-writes"
	return 0
}

tracked_repo="${TEST_ROOT}/tracked"
local_repo="${TEST_ROOT}/local"
linked_repo="${TEST_ROOT}/tracked-linked"
external_repo="${TEST_ROOT}/external"
make_repo "$tracked_repo" true
make_repo "$local_repo" false
make_repo "$external_repo" true
tracked_repo="$(cd "$tracked_repo" && pwd -P)"
local_repo="$(cd "$local_repo" && pwd -P)"
external_repo="$(cd "$external_repo" && pwd -P)"
"$TEST_NATIVE_GIT" -C "$tracked_repo" worktree add -q -b config-migration "$linked_repo"

jq -n --arg tracked "$tracked_repo" --arg local "$local_repo" --arg external "$external_repo" '{
  initialized_repos: [
		{path: $tracked, version: "0.0.1", features: ["planning"], agent_source: true},
		{path: $local, version: "0.0.1", features: ["planning"]},
		{path: $external, version: "0.0.1", features: ["planning"]}
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
assert_equal "tracked repository remains clean" "" "$("$TEST_NATIVE_GIT" -C "$tracked_repo" status --porcelain)"
assert_equal "maintained tracked config queues one migration" "true" "$(test -f "${TEST_ROOT}/migration-created" && printf true || printf false)"
assert_equal "external tracked config performs no GitHub write" "1" "$(wc -l <"${TEST_ROOT}/migration-writes" | tr -d ' ')"
assert_equal "tracked config does not gain agent-source metadata" "false" "$(jq -r 'has("agent_source")' "$tracked_repo/.aidevops.json")"
assert_equal "tracked registration advances" "9.9.9" "$(jq -r --arg path "$tracked_repo" '.initialized_repos[] | select(.path == $path) | .version' "$REPOS_FILE")"
assert_equal "tracked registration preserves features" "planning" "$(jq -r --arg path "$tracked_repo" '.initialized_repos[] | select(.path == $path) | .features | join(",")' "$REPOS_FILE")"
assert_equal "local config version advances" "9.9.9" "$(jq -r '.version' "$local_repo/.aidevops.json")"
assert_equal "local registration advances" "9.9.9" "$(jq -r --arg path "$local_repo" '.initialized_repos[] | select(.path == $path) | .version' "$REPOS_FILE")"
assert_equal "local repository remains clean" "" "$("$TEST_NATIVE_GIT" -C "$local_repo" status --porcelain)"

update_for_next_release 9.9.10
assert_equal "next release does not duplicate an open migration" "1" "$(wc -l <"${TEST_ROOT}/migration-writes" | tr -d ' ')"

# After a worker closes the issue, a canonical checkout that is behind still
# tracks the config locally; only the migrated default branch may decide.
rm -f "${TEST_ROOT}/migration-created"
touch "${TEST_ROOT}/remote-migrated"
update_for_next_release 9.9.11
assert_equal "stale local index does not re-file after default-branch migration" "1" "$(wc -l <"${TEST_ROOT}/migration-writes" | tr -d ' ')"

rm -f "${TEST_ROOT}/remote-migrated"
touch "${TEST_ROOT}/migration-lookup-fails"
update_for_next_release 9.9.12
assert_equal "failed duplicate lookup does not file a possible duplicate" "1" "$(wc -l <"${TEST_ROOT}/migration-writes" | tr -d ' ')"
rm -f "${TEST_ROOT}/migration-lookup-fails"

update_for_next_release 9.9.13
assert_equal "pending default-branch migration is re-queued once its issue closes" "2" "$(wc -l <"${TEST_ROOT}/migration-writes" | tr -d ' ')"

linked_before=$(cksum <"$linked_repo/.aidevops.json")
_project_config_migrate_linked_worktree "$linked_repo"
linked_after=$(cksum <"$linked_repo/.aidevops.json")
assert_equal "linked-worktree migration preserves config bytes" "$linked_before" "$linked_after"
assert_equal "linked-worktree migration removes config from index" "" "$("$TEST_NATIVE_GIT" -C "$linked_repo" ls-files -- .aidevops.json)"
assert_equal "linked-worktree migration stages only the config deletion" "D  .aidevops.json" "$("$TEST_NATIVE_GIT" -C "$linked_repo" status --porcelain)"
assert_equal "linked-worktree migration leaves canonical checkout clean" "" "$("$TEST_NATIVE_GIT" -C "$tracked_repo" status --porcelain)"

# GH#39023: init in a linked worktree saves its ignored config; update writes it
# to the canonical checkout only once that checkout's .gitignore ignores it.
# shellcheck source=../aidevops-cli/aidevops-init-lib.sh
source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"
init_repo="${TEST_ROOT}/init-canonical"
init_linked="${TEST_ROOT}/init-linked"
mkdir -p "$init_repo"
"$TEST_NATIVE_GIT" -C "$init_repo" init -q -b main
"$TEST_NATIVE_GIT" -C "$init_repo" config user.email test@example.invalid
"$TEST_NATIVE_GIT" -C "$init_repo" config user.name Test
"$TEST_NATIVE_GIT" -C "$init_repo" config commit.gpgsign false
"$TEST_NATIVE_GIT" -C "$init_repo" remote add origin https://github.com/example/init-backup.git
printf 'fixture\n' >"$init_repo/README.md"
"$TEST_NATIVE_GIT" -C "$init_repo" add README.md
"$TEST_NATIVE_GIT" -C "$init_repo" commit -qm fixture
init_repo="$(cd "$init_repo" && pwd -P)"
"$TEST_NATIVE_GIT" -C "$init_repo" worktree add -q -b chore/aidevops-init "$init_linked"
printf '%s\n' '{"version":"9.9.13","features":{"planning":true},"local_option":"kept"}' >"$init_linked/.aidevops.json"
jq --arg path "$init_repo" '.initialized_repos += [{path: $path, slug: "example/init-backup", version: "9.9.13", features: ["planning"], init_scope: "minimal"}]' "$REPOS_FILE" >"${REPOS_FILE}.next"
mv "${REPOS_FILE}.next" "$REPOS_FILE"
init_backup="${HOME}/.config/aidevops/project-config-backups/example--init-backup.json"
project_root="$init_linked"
_init_save_config_backup
assert_equal "linked-worktree init saves a byte-identical config copy" "true" "$(cmp -s "$init_linked/.aidevops.json" "$init_backup" && printf true || printf false)"
assert_equal "saved config copy is owner-only" "600" "$(stat -c '%a' "$init_backup" 2>/dev/null || stat -f '%Lp' "$init_backup")"

_update_sync_projects false 9.9.13
assert_equal "update writes nothing before the canonical ignore rule exists" "false" "$(test -e "$init_repo/.aidevops.json" && printf true || printf false)"
assert_equal "update keeps the saved copy until it can be restored" "true" "$(test -f "$init_backup" && printf true || printf false)"

# Simulate the merged bootstrap PR that adds the ignore rule.
printf '%s\n' '.aidevops.json' >"$init_repo/.gitignore"
"$TEST_NATIVE_GIT" -C "$init_repo" add .gitignore
"$TEST_NATIVE_GIT" -C "$init_repo" commit -qm "chore: initialize aidevops"
chmod 644 "$init_backup"
_update_sync_projects false 9.9.13
assert_equal "update refuses a saved copy that is not owner-only" "false" "$(test -e "$init_repo/.aidevops.json" && printf true || printf false)"
chmod 600 "$init_backup"
"$TEST_NATIVE_GIT" -C "$init_repo" worktree remove --force "$init_linked"
_update_sync_projects false 9.9.13
assert_equal "update restores the init output byte-identically" '{"version":"9.9.13","features":{"planning":true},"local_option":"kept"}' "$(cat "$init_repo/.aidevops.json" 2>/dev/null)"
assert_equal "restored config is ignored and the canonical checkout stays clean" "" "$("$TEST_NATIVE_GIT" -C "$init_repo" status --porcelain)"
assert_equal "restored saved copy is removed" "false" "$(test -e "$init_backup" && printf true || printf false)"

printf '%s\n' '{"version":"0.0.0","features":{}}' >"$init_backup"
chmod 600 "$init_backup"
_update_sync_projects false 9.9.13
assert_equal "existing canonical config is never overwritten" "kept" "$(jq -r '.local_option' "$init_repo/.aidevops.json")"
assert_equal "redundant saved copy is removed when canonical config exists" "false" "$(test -e "$init_backup" && printf true || printf false)"

orphan_backup="${HOME}/.config/aidevops/project-config-backups/example--unregistered.json"
printf '%s\n' '{"version":"0.0.0","features":{}}' >"$orphan_backup"
_update_sync_projects false 9.9.13
assert_equal "saved copy for an unregistered repository is pruned" "false" "$(test -e "$orphan_backup" && printf true || printf false)"

printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
[[ "$failed" -eq 0 ]]
