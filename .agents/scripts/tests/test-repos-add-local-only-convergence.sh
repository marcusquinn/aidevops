#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-repos-local-only.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
INSTALL_DIR="$REPO_ROOT"
AGENTS_DIR="$REPO_ROOT/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
REPOS_FILE="${CONFIG_DIR}/repos.json"
AIDEVOPS_REPOS_FILE="$REPOS_FILE"
export INSTALL_DIR AGENTS_DIR CONFIG_DIR REPOS_FILE AIDEVOPS_REPOS_FILE

mkdir -p "$CONFIG_DIR"

print_info() { return 0; }
print_warning() { return 0; }

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"
# shellcheck source=../dispatch-single-issue-helper.sh
source "$REPO_ROOT/.agents/scripts/dispatch-single-issue-helper.sh"

_repo_registration_maintainer() {
	printf '\n'
	return 0
}

repo_path="${TEST_ROOT}/repo"
mkdir -p "$repo_path"
git -C "$repo_path" init -q
repo_path="$(cd "$repo_path" && pwd -P)"

register_repo "$repo_path" "1.0.0" "planning"

[[ "$(jq -r '.initialized_repos[0].local_only' "$REPOS_FILE")" == "true" ]]
[[ "$(jq -r '.initialized_repos[0].pulse' "$REPOS_FILE")" == "false" ]]

git -C "$repo_path" remote add origin https://github.com/example/remote-backed.git
register_repo "$repo_path" "1.0.1" "planning"

[[ "$(jq -r '.initialized_repos[0].slug' "$REPOS_FILE")" == "example/remote-backed" ]]
[[ "$(jq -r '.initialized_repos[0] | has("local_only")' "$REPOS_FILE")" == "false" ]]
[[ "$(jq -r '.initialized_repos[0].pulse' "$REPOS_FILE")" == "false" ]]
[[ "$(_dsi_repo_path_for_slug "example/remote-backed")" == "$repo_path" ]]

printf 'PASS repos add clears stale local_only, preserves pulse, and restores dispatch path resolution\n'
