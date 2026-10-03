#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for GH#28485: init help and root .gitignore scaffolding.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEST_ROOT=""
PASSED=0
FAILED=0

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

ensure_trailing_newline() {
	local file="$1"
	local last=""
	if [[ -s "$file" ]]; then
		last="$(
			tail -c 1 "$file"
			printf x
		)"
		[[ "$last" == $'\n'x ]] || printf '\n' >>"$file"
	fi
	return 0
}

INSTALL_DIR="$REPO_ROOT"
AGENTS_DIR="$REPO_ROOT/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
# shellcheck source=../aidevops-cli/aidevops-init-lib.sh
source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

assert_file_count() {
	local expected="$1"
	local pattern="$2"
	local file="$3"
	local name="$4"
	local actual
	actual=$(grep -cFx "$pattern" "$file" || true)
	assert_equal "$expected" "$actual" "$name"
	return 0
}

test_help_outside_repository() {
	local non_repo="$TEST_ROOT/non-repo"
	local help_arg output_file rc
	mkdir -p "$non_repo"
	for help_arg in --help -h help; do
		output_file="$TEST_ROOT/help-${help_arg#-}.txt"
		rc=0
		(cd "$non_repo" && bash "$REPO_ROOT/aidevops.sh" init "$help_arg") >"$output_file" 2>&1 || rc=$?
		assert_equal 0 "$rc" "init $help_arg exits successfully outside a repository"
		assert_equal 1 "$(grep -cF 'Usage: aidevops init [FEATURES]' "$output_file" || true)" "init $help_arg prints init usage"
		assert_equal 0 "$(grep -cF 'Not in a git repository' "$output_file" || true)" "init $help_arg bypasses repository validation"
	done
	return 0
}

test_missing_gitignore_is_created() {
	local repo="$TEST_ROOT/new-gitignore"
	local before after entry
	mkdir -p "$repo"
	_init_update_gitignore "$repo" false
	assert_equal true "$([[ -f "$repo/.gitignore" ]] && printf true || printf false)" "missing root .gitignore is created"
	for entry in ".agents/loop-state/" ".agents/tmp/" ".agents/memory/" ".agents/commands" ".windsurf/" ".aidevops.json" ".env" ".env.*" "*.pem" "*.key" "*.p12" "*.pfx" "credentials.json"; do
		assert_file_count 1 "$entry" "$repo/.gitignore" "new .gitignore contains $entry once"
	done
	assert_file_count 0 ".beads" "$repo/.gitignore" "new .gitignore omits .beads when disabled"
	before=$(cksum "$repo/.gitignore")
	_init_update_gitignore "$repo" false
	after=$(cksum "$repo/.gitignore")
	assert_equal "$before" "$after" "new .gitignore rerun is byte-stable"
	return 0
}

test_existing_gitignore_is_preserved() {
	local repo="$TEST_ROOT/existing-gitignore"
	local before after entry
	mkdir -p "$repo"
	printf 'node_modules/\n.agents\n.agent\n.agents/tmp/\n.env\n' >"$repo/.gitignore"
	_init_update_gitignore "$repo" true
	assert_file_count 1 "node_modules/" "$repo/.gitignore" "user-owned ignore entry is preserved"
	assert_file_count 0 ".agents" "$repo/.gitignore" "legacy bare .agents entry is removed"
	assert_file_count 0 ".agent" "$repo/.gitignore" "legacy bare .agent entry is removed"
	for entry in ".agents/loop-state/" ".agents/tmp/" ".agents/memory/" ".agents/commands" ".windsurf/" ".aidevops.json" ".env" ".env.*" "*.pem" "*.key" "*.p12" "*.pfx" "credentials.json" ".beads"; do
		assert_file_count 1 "$entry" "$repo/.gitignore" "existing .gitignore contains $entry once"
	done
	before=$(cksum "$repo/.gitignore")
	_init_update_gitignore "$repo" true
	after=$(cksum "$repo/.gitignore")
	assert_equal "$before" "$after" "existing .gitignore rerun is byte-stable"
	return 0
}

# GH#33345: every slash command recommended by the init summary must resolve
# through the documented command contract (scripts/commands, main-agent
# commands, or workflows fallback); legacy /create-prd and /feature did not.
test_summary_recommends_resolvable_commands() {
	local output_file="$TEST_ROOT/init-summary.txt"
	local commands_found=0
	local name=""
	init_security_posture="ok"
	init_scope="standard"
	enable_planning=true
	enable_git_workflow=true
	enable_code_quality=false
	enable_time_tracking=false
	enable_database=false
	enable_sops=false
	enable_security=false
	enable_deployment_context=false
	enable_wordpress_context=false
	project_root="$TEST_ROOT"
	committed=true
	WORKTREE_PATH=""
	_init_print_summary >"$output_file" 2>&1
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		commands_found=$((commands_found + 1))
		if [[ -f "$AGENTS_DIR/scripts/commands/${name}.md" || -f "$AGENTS_DIR/commands/${name}.md" || -f "$AGENTS_DIR/workflows/${name}.md" ]]; then
			assert_equal true true "init summary command /$name resolves"
		else
			assert_equal resolvable "missing" "init summary command /$name resolves"
		fi
	done < <(grep -oE '(^|[[:space:]])/[a-z][a-z0-9-]*' "$output_file" | sed -E 's#^[[:space:]]*/##' | sort -u)
	assert_equal true "$([[ "$commands_found" -gt 0 ]] && printf true || printf false)" "init summary recommends at least one slash command"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_help_outside_repository
	test_missing_gitignore_is_created
	test_existing_gitignore_is_preserved
	test_summary_recommends_resolvable_commands
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
