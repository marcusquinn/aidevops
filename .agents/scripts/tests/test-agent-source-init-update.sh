#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-agent-source-init-update.sh — regression tests for agent-source repo seeding

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

_TESTS_RUN=0
_TESTS_FAILED=0

print_success() { printf '  INFO: %s\n' "$*"; return 0; }
print_warning() { printf '  WARN: %s\n' "$*"; return 0; }
print_info() { printf '  INFO: %s\n' "$*"; return 0; }
print_header() { printf '\n== %s ==\n' "$*"; return 0; }

assert_file_exists() {
	local description="$1"
	local path="$2"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if [[ -e "$path" ]]; then
		printf '  PASS: %s\n' "$description"
	else
		_TESTS_FAILED=$((_TESTS_FAILED + 1))
		printf '  FAIL: %s (missing %s)\n' "$description" "$path"
	fi
	return 0
}

assert_contains() {
	local description="$1"
	local path="$2"
	local needle="$3"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if grep -Fq "$needle" "$path" 2>/dev/null; then
		printf '  PASS: %s\n' "$description"
	else
		_TESTS_FAILED=$((_TESTS_FAILED + 1))
		printf '  FAIL: %s (needle=%s path=%s)\n' "$description" "$needle" "$path"
	fi
	return 0
}

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf '  PASS: %s\n' "$description"
	else
		_TESTS_FAILED=$((_TESTS_FAILED + 1))
		printf '  FAIL: %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export HOME="$TMPDIR_TEST/home"
INSTALL_DIR="$REPO_ROOT"
SCRIPT_DIR="$REPO_ROOT"
AGENTS_DIR="$REPO_ROOT/.agents"
CONFIG_DIR="$TMPDIR_TEST/config"
REPOS_FILE="$CONFIG_DIR/repos.json"
mkdir -p "$CONFIG_DIR" "$HOME"

# shellcheck source=../../../aidevops-repos-lib.sh
source "$REPO_ROOT/aidevops-repos-lib.sh"
# shellcheck source=../../../aidevops-init-lib.sh
source "$REPO_ROOT/aidevops-init-lib.sh"
# shellcheck source=../../../aidevops-update-lib.sh
source "$REPO_ROOT/aidevops-update-lib.sh"

agent_repo="$TMPDIR_TEST/private-agent-pack"
mkdir -p "$agent_repo"
cat >"$REPOS_FILE" <<JSON
{
  "initialized_repos": [
    {"path": "$agent_repo", "agent_source": true, "version": "0.0.1"}
  ],
  "git_parent_dirs": []
}
JSON

print_header "agent-source seed"
if is_agent_source_repo "$agent_repo"; then
	assert_eq "repos.json flag detects agent source" "true" "true"
else
	assert_eq "repos.json flag detects agent source" "true" "false"
fi

seed_agent_source_repo_templates "$agent_repo"
assert_file_exists "root AGENTS.md seeded" "$agent_repo/AGENTS.md"
assert_file_exists ".agents/AGENTS.md seeded" "$agent_repo/.agents/AGENTS.md"
assert_file_exists "tools skeleton seeded" "$agent_repo/.agents/tools"
assert_file_exists "scripts/commands skeleton seeded" "$agent_repo/.agents/scripts/commands"
assert_contains "managed marker present" "$agent_repo/AGENTS.md" "aidevops:agent-source-template-version: 1"

before_hash=$(shasum "$agent_repo/AGENTS.md" | cut -d' ' -f1)
seed_agent_source_repo_templates "$agent_repo"
after_hash=$(shasum "$agent_repo/AGENTS.md" | cut -d' ' -f1)
assert_eq "idempotent re-run leaves managed file stable" "$before_hash" "$after_hash"

print_header "agent-source update"
python3 - "$agent_repo/AGENTS.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('aidevops:agent-source-template-version: 1', 'aidevops:agent-source-template-version: 0')
path.write_text(text + '\nUser-authored note outside managed block.\n')
PY

_update_sync_agent_source_repos "9.9.9"
assert_contains "update refreshes managed block" "$agent_repo/AGENTS.md" "aidevops:agent-source-template-version: 1"
assert_contains "update preserves user content outside block" "$agent_repo/AGENTS.md" "User-authored note outside managed block."

version=$(jq -r '.agent_source as $a | .version + ":" + ($a|tostring)' "$agent_repo/.aidevops.json" 2>/dev/null || true)
assert_eq "update writes project agent_source metadata only when config exists" "" "$version"

printf '\nResults: %d/%d passed, %d failed\n' "$((_TESTS_RUN - _TESTS_FAILED))" "$_TESTS_RUN" "$_TESTS_FAILED"
if [[ "$_TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
