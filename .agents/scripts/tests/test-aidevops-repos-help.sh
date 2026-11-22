#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-repos-help.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
CONFIG_DIR="${HOME}/.config/aidevops"
REPOS_FILE="${CONFIG_DIR}/repos.json"
FIRST_REPO="${TEST_ROOT}/first"
SECOND_REPO="${TEST_ROOT}/second"
mkdir -p "$CONFIG_DIR" "$FIRST_REPO" "$SECOND_REPO"

write_fixture() {
	jq -n --arg first "$FIRST_REPO" --arg second "$SECOND_REPO" \
		'{initialized_repos: [{path: $first, custom: "preserved"}, {path: $second}]}' >"$REPOS_FILE"
	return 0
}

fail() {
	printf 'FAIL %s\n' "$1"
	exit 1
}

for action in remove rm; do
	for help_arg in help -h --help; do
		write_fixture
		cp "$REPOS_FILE" "${REPOS_FILE}.before"
		output=$(bash "$REPO_ROOT/aidevops.sh" repos "$action" "$help_arg") || fail "$action $help_arg returned non-zero"
		[[ "$output" == *"Usage: aidevops repos remove"* ]] || fail "$action $help_arg omitted scoped usage"
		cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "$action $help_arg changed the registry"
		[[ ! -e "${REPOS_FILE}.tmp" ]] || fail "$action $help_arg left a temporary registry"
	done
done

write_fixture
bash "$REPO_ROOT/aidevops.sh" repos remove "$FIRST_REPO" >/dev/null
[[ "$(jq '.initialized_repos | length' "$REPOS_FILE")" -eq 1 ]] || fail "valid removal changed the wrong number of entries"
[[ "$(jq -r '.initialized_repos[0].path' "$REPOS_FILE")" == "$SECOND_REPO" ]] || fail "valid removal did not preserve the unrelated entry"

cp "$REPOS_FILE" "${REPOS_FILE}.before"
if bash "$REPO_ROOT/aidevops.sh" repos remove "${TEST_ROOT}/missing" >/dev/null 2>&1; then
	fail "missing repository reported successful removal"
fi
cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "missing repository changed the registry"
[[ ! -e "${REPOS_FILE}.tmp" ]] || fail "missing repository left a temporary registry"

printf 'PASS repos remove help is read-only and removals report truthful outcomes\n'

for help_arg in help -h --help; do
	cp "$REPOS_FILE" "${REPOS_FILE}.before"
	output=$(bash "$REPO_ROOT/aidevops.sh" repos add "$help_arg") || fail "add help returned non-zero"
	[[ "$output" == *"--sync-only"* ]] || fail "add help omitted sync-only"
	cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "add help changed the registry"
done
output=$(bash "$REPO_ROOT/aidevops.sh" repos --help)
[[ "$output" == *"--sync-only"* ]] || fail "repos help omitted sync-only"

# Keep CLI registration deterministic and offline, including role detection.
gh() {
	local command="${1:-}"
	local subject="${2:-}"
	if [[ "$command" == "api" && "$subject" == "user" ]]; then
		printf 'alice\n'
		return 0
	fi
	if [[ "$command" == "repo" && "$subject" == "view" ]]; then
		printf 'READ\n'
		return 0
	fi
	return 1
}
export -f gh

make_registration_repo() {
	local repo_path="$1"
	mkdir -p "$repo_path"
	git -C "$repo_path" init -q
	git -C "$repo_path" remote add origin "https://github.com/example/remote-backed.git"
	printf '%s\n' '{"version":"1.0.0","features":{"planning":true},"init_scope":"standard"}' >"$repo_path/.aidevops.json"
	return 0
}

SYNC_REPO="${TEST_ROOT}/sync only"
DEFAULT_REPO="${TEST_ROOT}/default"
make_registration_repo "$SYNC_REPO"
make_registration_repo "$DEFAULT_REPO"
bash "$REPO_ROOT/aidevops.sh" repos add "$SYNC_REPO" --sync-only >/dev/null
jq -e --arg path "$SYNC_REPO" '.initialized_repos[] | select(.path == $path) |
	.pulse == false and .maintenance == false and .role == "contributor"' "$REPOS_FILE" >/dev/null || fail "new sync-only entry lost opt-outs or detected role"

output=$(bash "$REPO_ROOT/aidevops.sh" repos add "$DEFAULT_REPO")
[[ "$output" == *"Registered default"* ]] || fail "plain add changed its success output"
jq -e --arg path "$DEFAULT_REPO" '.initialized_repos[] | select(.path == $path) |
	.pulse == true and (has("maintenance") | not)' "$REPOS_FILE" >/dev/null || fail "plain add changed registration defaults"

jq --arg path "$DEFAULT_REPO" '(.initialized_repos[] | select(.path == $path)) +=
	{role: "maintainer", custom: "preserved", maintenance: true}' "$REPOS_FILE" >"${REPOS_FILE}.tmp"
mv "${REPOS_FILE}.tmp" "$REPOS_FILE"
bash "$REPO_ROOT/aidevops.sh" repos add --sync-only "$DEFAULT_REPO" >/dev/null
jq -e --arg path "$DEFAULT_REPO" '.initialized_repos[] | select(.path == $path) |
	.pulse == false and .maintenance == false and .role == "maintainer" and .custom == "preserved"' "$REPOS_FILE" >/dev/null || fail "existing sync-only entry lost role, opt-outs or custom fields"
(
	cd "$DEFAULT_REPO"
	bash "$REPO_ROOT/aidevops.sh" repos add >/dev/null
)
jq -e --arg path "$DEFAULT_REPO" '.initialized_repos[] | select(.path == $path) |
	.pulse == false and .maintenance == false' "$REPOS_FILE" >/dev/null || fail "plain re-registration resumed automation"

cp "$REPOS_FILE" "${REPOS_FILE}.before"
for bad_argument in --unknown "$SECOND_REPO"; do
	if bash "$REPO_ROOT/aidevops.sh" repos add "$SYNC_REPO" "$bad_argument" >/dev/null 2>&1; then
		fail "add accepted unknown flag or duplicate path"
	fi
	cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "invalid add changed registry"
done
git -C "$FIRST_REPO" init -q
if bash "$REPO_ROOT/aidevops.sh" repos add "$FIRST_REPO" --sync-only >/dev/null 2>&1; then
	fail "sync-only bypassed config-free bootstrap confirmation"
fi
cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "rejected bootstrap changed registry"

printf 'PASS sync-only help, new/existing registration, role preservation and unchanged defaults\n'

# Simulate missing jq without hiding the other tools needed by the real CLI.
(
	command() {
		local option="${1:-}"
		local tool="${2:-}"
		if [[ "$option" == "-v" && "$tool" == "jq" ]]; then
			return 1
		fi
		builtin command "$@"
		return $?
	}
	export -f command
	# Seed enabled automation to ensure failure cannot masquerade as an opt-out.
	jq --arg path "$DEFAULT_REPO" '(.initialized_repos[] | select(.path == $path)) +=
		{pulse: true, maintenance: true}' "$REPOS_FILE" >"${REPOS_FILE}.tmp"
	mv "${REPOS_FILE}.tmp" "$REPOS_FILE"
	cp "$REPOS_FILE" "${REPOS_FILE}.before"
	if output=$(bash "$REPO_ROOT/aidevops.sh" repos add "$DEFAULT_REPO" --sync-only 2>&1); then
		fail "sync-only registration reported success without jq"
	fi
	[[ "$output" == *"jq is required for sync-only registration"* ]] || fail "missing jq omitted actionable diagnostic"
	cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "missing jq changed registry"
	bash "$REPO_ROOT/aidevops.sh" repos add "$DEFAULT_REPO" >/dev/null
	cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "ordinary registration without jq changed registry"
)
