#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-simplification-state-preserve.sh — regression guard for GH#22523.
#
# setup.sh --non-interactive can run the simplification-state maintenance path.
# _simplification_state_prune() must remove stale file entries without
# rewriting the shared registry into a lossy {"files": ...}-only shape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
STATE_SCRIPT="${SCRIPT_DIR}/../pulse-simplification-state.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# shellcheck source=/dev/null
source "$STATE_SCRIPT"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_repo() {
	TEST_ROOT=$(mktemp -d)
	local repo_path="${TEST_ROOT}/repo"
	mkdir -p "${repo_path}/.agents/configs" "${repo_path}/.agents/reference" "${repo_path}/.agents/scripts/setup/modules"
	git -C "$repo_path" init -q 2>/dev/null
	git -C "$repo_path" config user.email "test@test.com" 2>/dev/null
	git -C "$repo_path" config user.name "Test" 2>/dev/null
	printf 'keep\n' >"${repo_path}/.agents/reference/bash-fd-locking.md"
	printf 'deploy\n' >"${repo_path}/.agents/scripts/setup/modules/agent-deploy.sh"
	git -C "$repo_path" add . 2>/dev/null
	git -C "$repo_path" commit -q -m "init" 2>/dev/null
	printf '%s\n' "$repo_path"
	return 0
}

teardown_test_repo() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

repo_path=$(setup_test_repo)
state_file="${repo_path}/.agents/configs/simplification-state.json"

cat >"$state_file" <<'JSON'
{
  ".agents/content/youtube-setup.md": {
    "hash": "legacy-top-level-entry",
    "at": "2026-05-03T00:00:00Z",
    "pr": 111
  },
  "schema_version": 1,
  "files": {
    ".agents/reference/bash-fd-locking.md": {
      "hash": "keep-file-entry",
      "at": "2026-05-03T00:00:00Z",
      "pr": 222,
      "passes": 1
    },
    ".agents/reference/missing.md": {
      "hash": "stale-file-entry",
      "at": "2026-05-03T00:00:00Z",
      "pr": 333,
      "passes": 1
    },
    ".agents/scripts/setup/modules/agent-deploy.sh": {
      "hash": "keep-deploy-entry",
      "at": "2026-05-03T00:00:00Z",
      "pr": 444,
      "passes": 2
    }
  }
}
JSON

pruned=$(_simplification_state_prune "$repo_path" "$state_file")
print_result "prunes exactly one stale nested files entry" "$([[ "$pruned" == "1" ]] && printf 0 || printf 1)" "expected pruned=1, got ${pruned}"

top_level_hash=$(jq -r '.".agents/content/youtube-setup.md".hash // empty' "$state_file")
print_result "preserves unrelated legacy top-level registry entries" "$([[ "$top_level_hash" == "legacy-top-level-entry" ]] && printf 0 || printf 1)" "top-level entry was lost or changed"

schema_version=$(jq -r '.schema_version // empty' "$state_file")
print_result "preserves unrelated top-level metadata" "$([[ "$schema_version" == "1" ]] && printf 0 || printf 1)" "schema_version was lost or changed"

kept_file_hash=$(jq -r '.files[".agents/reference/bash-fd-locking.md"].hash // empty' "$state_file")
print_result "preserves existing nested files entries" "$([[ "$kept_file_hash" == "keep-file-entry" ]] && printf 0 || printf 1)" "nested file entry was lost or changed"

deploy_hash=$(jq -r '.files[".agents/scripts/setup/modules/agent-deploy.sh"].hash // empty' "$state_file")
print_result "preserves setup module nested files entry" "$([[ "$deploy_hash" == "keep-deploy-entry" ]] && printf 0 || printf 1)" "agent-deploy nested entry was lost or changed"

stale_hash=$(jq -r '.files[".agents/reference/missing.md"].hash // empty' "$state_file")
print_result "removes only the stale nested files entry" "$([[ -z "$stale_hash" ]] && printf 0 || printf 1)" "stale entry still exists"

teardown_test_repo

printf '\n'
printf '%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
