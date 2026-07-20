#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
INSTALL_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
AGENTS_DIR="$INSTALL_DIR/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
TEST_ROOT=""
PASSED=0
FAILED=0
RESOLVED_GIT=""
RESOLVED_GIT=$(command -p -v git 2>/dev/null || command -v git 2>/dev/null) || RESOLVED_GIT=""
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-${RESOLVED_GIT:-git}}"

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

# shellcheck source=../aidevops-cli/aidevops-init-lib.sh
source "$INSTALL_DIR/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"
_init_print_summary() { return 0; }
git() {
	"$GIT_BIN" "$@"
	return $?
}

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
		printf "PASS %s\n" "$name"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf "FAIL %s (expected=%s actual=%s)\n" "$name" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

assert_feature() {
	local input="$1"
	local feature="$2"
	local expected="$3"
	local parsed
	parsed=" $(_init_parse_features "$input") "
	local actual=false
	[[ "$parsed" == *" $feature "* ]] && actual=true
	assert_equal "$expected" "$actual" "$input resolves $feature"
	return 0
}

test_feature_parsing() {
	assert_feature deployment-context deployment_context true
	assert_feature hosting-context deployment_context true
	assert_feature wordpress-context wordpress_context true
	assert_feature wordpress-context deployment_context true
	assert_feature all deployment_context false
	assert_feature all wordpress_context false
	return 0
}

test_scaffold_and_idempotency() {
	local repo="$TEST_ROOT/scaffold"
	mkdir -p "$repo/.agents"
	printf "before\n" >"$repo/.agents/AGENTS.md"
	_init_scaffold_project_context "$repo" true true
	assert_equal true "$([[ -f "$repo/.aidevops/deployments.yaml" ]] && printf true || printf false)" "deployment manifest scaffolded"
	assert_equal true "$([[ -f "$repo/.aidevops/wordpress.yaml" ]] && printf true || printf false)" "WordPress manifest scaffolded"
	assert_equal true "$([[ -f "$repo/.aidevops/.gitignore" ]] && printf true || printf false)" "private artifact ignore scaffolded"

	printf "user deployment content\n" >"$repo/.aidevops/deployments.yaml"
	printf "user WordPress content\n" >"$repo/.aidevops/wordpress.yaml"
	printf "after\n" >>"$repo/.agents/AGENTS.md"
	local before
	before=$(cksum "$repo/.agents/AGENTS.md")
	_init_scaffold_project_context "$repo" true true
	assert_equal "user deployment content" "$(tr -d "\n" <"$repo/.aidevops/deployments.yaml")" "existing deployment manifest preserved"
	assert_equal "user WordPress content" "$(tr -d "\n" <"$repo/.aidevops/wordpress.yaml")" "existing WordPress manifest preserved"
	assert_equal "$before" "$(cksum "$repo/.agents/AGENTS.md")" "rerun is byte-stable"
	assert_equal 1 "$(grep -c "aidevops:project-operations-context:start" "$repo/.agents/AGENTS.md" || true)" "marker block appears once"
	assert_equal 1 "$(grep -c "before" "$repo/.agents/AGENTS.md" || true)" "content before marker preserved"
	assert_equal 1 "$(grep -c "after" "$repo/.agents/AGENTS.md" || true)" "content after marker preserved"

	local deployment_only="$TEST_ROOT/deployment-only"
	mkdir -p "$deployment_only/.agents"
	printf "# Context\n" >"$deployment_only/.agents/AGENTS.md"
	_init_scaffold_project_context "$deployment_only" true false
	assert_equal 1 "$(grep -c "deployments.yaml" "$deployment_only/.agents/AGENTS.md" || true)" "pointer lists existing deployment manifest"
	assert_equal 0 "$(grep -c "wordpress.yaml" "$deployment_only/.agents/AGENTS.md" || true)" "pointer omits absent WordPress manifest"
	return 0
}

test_agents_context_write_failures_preserve_original() {
	local repo="$TEST_ROOT/write-failures"
	local agents_md="$repo/.agents/AGENTS.md"
	local original
	mkdir -p "$repo/.agents" "$repo/.aidevops"
	printf "before\n<!-- aidevops:project-operations-context:start -->\nold\n<!-- aidevops:project-operations-context:end -->\nafter\n" >"$agents_md"
	original=$(cksum "$agents_md")

	awk() { return 1; }
	if _init_update_project_operations_context "$repo"; then
		assert_equal failure success "awk failure is reported"
	else
		assert_equal failure failure "awk failure is reported"
	fi
	unset -f awk
	assert_equal "$original" "$(cksum "$agents_md")" "awk failure preserves AGENTS.md"
	assert_equal false "$(compgen -G "${agents_md}.project-context*" >/dev/null && printf true || printf false)" "awk failure removes temporary files"

	printf "before\n" >"$agents_md"
	original=$(cksum "$agents_md")
	cp() { return 1; }
	if _init_update_project_operations_context "$repo"; then
		assert_equal failure success "cp failure is reported"
	else
		assert_equal failure failure "cp failure is reported"
	fi
	unset -f cp
	assert_equal "$original" "$(cksum "$agents_md")" "cp failure preserves AGENTS.md"
	assert_equal false "$(compgen -G "${agents_md}.project-context*" >/dev/null && printf true || printf false)" "cp failure removes temporary files"

	printf "before\n" >"$agents_md"
	original=$(cksum "$agents_md")
	cat() { return 1; }
	if _init_update_project_operations_context "$repo"; then
		assert_equal failure success "cat failure is reported"
	else
		assert_equal failure failure "cat failure is reported"
	fi
	unset -f cat
	assert_equal "$original" "$(cksum "$agents_md")" "cat failure preserves AGENTS.md"
	assert_equal false "$(compgen -G "${agents_md}.project-context*" >/dev/null && printf true || printf false)" "cat failure removes temporary files"
	return 0
}

test_config_booleans() {
	local config="$TEST_ROOT/config.json"
	_init_write_project_config "$config" 9.9.9 minimal false false false false false false false false false false true true
	assert_equal true "$(jq -r ".features.deployment_context" "$config")" "deployment context stored in config"
	assert_equal true "$(jq -r ".features.wordpress_context" "$config")" "WordPress context stored in config"
	jq ".custom = {\"preserved\": true}" "$config" >"$config.tmp"
	mv "$config.tmp" "$config"
	_init_write_project_config "$config" 9.9.10 minimal false false false false false false false false false false true true
	assert_equal true "$(jq -r ".custom.preserved" "$config")" "unknown config keys preserved"
	return 0
}

test_secret_reference_contract() {
	local closte_guide="$INSTALL_DIR/.agents/services/hosting/closte.md"
	local deployment_template="$AGENTS_DIR/templates/project-context/deployments.yaml"
	assert_equal 0 "$(grep -c "aidevops secret get" "$closte_guide" || true)" "Closte guide never retrieves secret values"
	assert_equal 2 "$(grep -c "aidevops secret SITE_SSH_HOST SITE_SSH_PORT SITE_SSH_USER SITE_SSH_PASSWORD -- sh -c" "$closte_guide" || true)" "Closte commands inject the four site SSH secrets"
	assert_equal 4 "$(grep -c "aidevops secret set SITE_SSH_" "$closte_guide" || true)" "Closte guide stores four site SSH secrets interactively"
	assert_equal 9 "$(grep -c "_secret_name:" "$deployment_template" || true)" "deployment manifest exposes only connection secret-name fields"
	assert_equal 2 "$(grep -c "port_secret_name:" "$deployment_template" || true)" "deployment manifest references SSH and database port secret names"
	assert_equal 2 "$(grep -c "username_secret_name:" "$deployment_template" || true)" "deployment manifest references SSH and database user secret names"
	assert_equal 2 "$(grep -c "password_secret_name:" "$deployment_template" || true)" "deployment manifest references SSH and database password secret names"
	assert_equal 0 "$(grep -Ec "^      (host|port|name|username|password|credential_secret):" "$deployment_template" || true)" "deployment manifest contains no inline SSH connection values"
	return 0
}

test_commit_inclusion() {
	local project_root="$TEST_ROOT/commit"
	mkdir -p "$project_root/.agents"
	git -C "$project_root" init --quiet
	git -C "$project_root" config user.name "Test User"
	git -C "$project_root" config user.email "test@example.invalid"
	printf "# Test\n" >"$project_root/.agents/AGENTS.md"
	_init_scaffold_project_context "$project_root" true true
	local aidevops_version=9.9.9
	local init_scope=minimal
	local committed=false
	_init_commit_files
	assert_equal true "$(git -C "$project_root" ls-files --error-unmatch .aidevops/deployments.yaml >/dev/null 2>&1 && printf true || printf false)" "deployment manifest included in init commit"
	assert_equal true "$(git -C "$project_root" ls-files --error-unmatch .aidevops/wordpress.yaml >/dev/null 2>&1 && printf true || printf false)" "WordPress manifest included in init commit"
	assert_equal true "$(git -C "$project_root" ls-files --error-unmatch .aidevops/.gitignore >/dev/null 2>&1 && printf true || printf false)" "context gitignore included in init commit"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_feature_parsing
	test_scaffold_and_idempotency
	test_agents_context_write_failures_preserve_original
	local full_repo="$TEST_ROOT/full-rerun"
	mkdir -p "$full_repo"
	scaffold_agents_md "$full_repo"
	_init_scaffold_project_context "$full_repo" true true
	local full_before
	full_before=$(cksum "$full_repo/.agents/AGENTS.md")
	scaffold_agents_md "$full_repo"
	_init_scaffold_project_context "$full_repo" true true
	assert_equal "$full_before" "$(cksum "$full_repo/.agents/AGENTS.md")" "generated AGENTS.md rerun is byte-stable"
	assert_equal 1 "$(grep -c "aidevops:project-operations-context:start" "$full_repo/.agents/AGENTS.md" || true)" "generated AGENTS.md marker appears once"

	test_config_booleans
	test_secret_reference_contract
	test_commit_inclusion
	printf "\nRan %d tests, %d failed.\n" "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
